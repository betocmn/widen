import CryptoKit
import Foundation

public enum OpenRouterCapabilitySource: String, Codable, Equatable, Sendable {
    case authenticatedCatalog
    case singleModelLookup
    case staleCache
    case conservativeDefault
}

public enum OpenRouterStructuredOutputMode: String, Codable, Equatable, Sendable {
    case strictJSONSchema
    case promptOnlyJSON
}

public struct OpenRouterModelCapabilities: Codable, Equatable, Sendable {
    public var supportsResponseFormat: Bool
    public var supportsStructuredOutputs: Bool
    public var supportsTools: Bool
    public var supportsToolChoice: Bool
    public var supportsTemperature: Bool
    public var supportsSeed: Bool
    public var supportsMaxTokens: Bool
    public var supportsMaxCompletionTokens: Bool
    public var contextLength: Int?
    public var maximumCompletionTokens: Int?
    public var capabilitySource: OpenRouterCapabilitySource
    public var fetchedAt: Date
    public var canonicalModelID: String? = nil

    public static func conservative(fetchedAt: Date = Date()) -> OpenRouterModelCapabilities {
        OpenRouterModelCapabilities(
            supportsResponseFormat: false,
            supportsStructuredOutputs: false,
            supportsTools: false,
            supportsToolChoice: false,
            supportsTemperature: false,
            supportsSeed: false,
            supportsMaxTokens: false,
            supportsMaxCompletionTokens: false,
            contextLength: nil,
            maximumCompletionTokens: nil,
            capabilitySource: .conservativeDefault,
            fetchedAt: fetchedAt
        )
    }
}

struct OpenRouterModelCapabilitiesLookup: Equatable, Sendable {
    var capabilities: OpenRouterModelCapabilities
    var httpRequestCount: Int
}

public struct OpenRouterPricing: Codable, Equatable, Sendable {
    public var prompt: String?
    public var completion: String?
    public var request: String?
    public var image: String?
}

public struct OpenRouterModelMetadata: Codable, Identifiable, Equatable, Sendable {
    public var requestedID: String
    public var id: String
    public var canonicalModelID: String?
    public var displayName: String
    public var contextLength: Int?
    public var maximumCompletionTokens: Int?
    public var supportedParameters: [String]
    public var pricing: OpenRouterPricing?
    public var expiration: String?
    public var isAvailableToAPIKey: Bool
    public var capabilitySource: OpenRouterCapabilitySource
    public var fetchedAt: Date

    public var capabilities: OpenRouterModelCapabilities {
        let parameters = Set(supportedParameters.map { $0.lowercased() })
        return OpenRouterModelCapabilities(
            supportsResponseFormat: parameters.contains("response_format"),
            supportsStructuredOutputs: parameters.contains("structured_outputs"),
            supportsTools: parameters.contains("tools"),
            supportsToolChoice: parameters.contains("tool_choice"),
            supportsTemperature: parameters.contains("temperature"),
            supportsSeed: parameters.contains("seed"),
            supportsMaxTokens: parameters.contains("max_tokens"),
            supportsMaxCompletionTokens: parameters.contains("max_completion_tokens"),
            contextLength: contextLength,
            maximumCompletionTokens: maximumCompletionTokens,
            capabilitySource: capabilitySource,
            fetchedAt: fetchedAt,
            canonicalModelID: canonicalModelID
        )
    }
}

public enum OpenRouterSchemaToolAppRejectionReason: String, Codable, Equatable, Sendable {
    case uninspectedObject
    case invalidSQL
    case intentCoverageRejected
    case unsupportedAction
    case malformedTerminal
    case budgetExhausted
    case timedOut
    case clarificationRejected
}

public struct OpenRouterSchemaToolEvidenceSummary: Codable, Equatable, Sendable {
    public var searched: Bool
    public var describedTableIDs: [String]
    public var exposedColumnIDs: [String]
    public var exposedForeignKeyPathIDs: [String]
    public var inspectedConstraintToolUsed: Bool
    public var inspectedValueToolUsed: Bool

    public init(
        searched: Bool = false,
        describedTableIDs: [String] = [],
        exposedColumnIDs: [String] = [],
        exposedForeignKeyPathIDs: [String] = [],
        inspectedConstraintToolUsed: Bool = false,
        inspectedValueToolUsed: Bool = false
    ) {
        self.searched = searched
        self.describedTableIDs = describedTableIDs
        self.exposedColumnIDs = exposedColumnIDs
        self.exposedForeignKeyPathIDs = exposedForeignKeyPathIDs
        self.inspectedConstraintToolUsed = inspectedConstraintToolUsed
        self.inspectedValueToolUsed = inspectedValueToolUsed
    }
}

public struct OpenRouterSchemaToolAgentDiagnostics: Codable, Equatable, Sendable {
    public var logicalTurnCount: Int?
    public var terminalToolSeen: Bool
    public var terminalAction: String?
    public var terminalQueryPlan: String
    public var terminalValidationFailureReason: String?
    public var triedSchemaToolsAfterTerminal: Bool
    public var producedProseInsteadOfTools: Bool
    public var redundantDuplicateToolCallCount: Int
    public var redundantZeroResultSearchCount: Int
    public var redundantJoinPathCallCount: Int
    public var schemaEvidence: OpenRouterSchemaToolEvidenceSummary
    public var appSideRejectionReason: OpenRouterSchemaToolAppRejectionReason?
    public var clarificationCorrectionMode: String
    public var intentCoverageMode: String
    public var clarificationPolicyDecision: String
    public var clarificationPolicyReason: String
    public var overClarificationCorrectionAttempted: Bool
    public var overClarificationCorrectionSucceeded: Bool
    public var databaseContextFactsUsed: [String]
    public var evidenceSufficientForSQL: Bool
    public var unresolvedDecisionKinds: [String]
    public var sqlIntentCoverageDecision: String
    public var sqlIntentCoverageReason: String
    public var sqlIntentCoverageMissingSignals: [String]
    public var sqlIntentCoverageMismatchCategory: String
    public var intentCoverageCorrectionAttempted: Bool
    public var intentCoverageCorrectionSucceeded: Bool

    public init(
        logicalTurnCount: Int? = nil,
        terminalToolSeen: Bool = false,
        terminalAction: String? = nil,
        terminalQueryPlan: String = "",
        terminalValidationFailureReason: String? = nil,
        triedSchemaToolsAfterTerminal: Bool = false,
        producedProseInsteadOfTools: Bool = false,
        redundantDuplicateToolCallCount: Int = 0,
        redundantZeroResultSearchCount: Int = 0,
        redundantJoinPathCallCount: Int = 0,
        schemaEvidence: OpenRouterSchemaToolEvidenceSummary = OpenRouterSchemaToolEvidenceSummary(),
        appSideRejectionReason: OpenRouterSchemaToolAppRejectionReason? = nil,
        clarificationCorrectionMode: String = "",
        intentCoverageMode: String = "",
        clarificationPolicyDecision: String = "",
        clarificationPolicyReason: String = "",
        overClarificationCorrectionAttempted: Bool = false,
        overClarificationCorrectionSucceeded: Bool = false,
        databaseContextFactsUsed: [String] = [],
        evidenceSufficientForSQL: Bool = false,
        unresolvedDecisionKinds: [String] = [],
        sqlIntentCoverageDecision: String = "",
        sqlIntentCoverageReason: String = "",
        sqlIntentCoverageMissingSignals: [String] = [],
        sqlIntentCoverageMismatchCategory: String = "",
        intentCoverageCorrectionAttempted: Bool = false,
        intentCoverageCorrectionSucceeded: Bool = false
    ) {
        self.logicalTurnCount = logicalTurnCount
        self.terminalToolSeen = terminalToolSeen
        self.terminalAction = terminalAction
        self.terminalQueryPlan = terminalQueryPlan
        self.terminalValidationFailureReason = terminalValidationFailureReason
        self.triedSchemaToolsAfterTerminal = triedSchemaToolsAfterTerminal
        self.producedProseInsteadOfTools = producedProseInsteadOfTools
        self.redundantDuplicateToolCallCount = redundantDuplicateToolCallCount
        self.redundantZeroResultSearchCount = redundantZeroResultSearchCount
        self.redundantJoinPathCallCount = redundantJoinPathCallCount
        self.schemaEvidence = schemaEvidence
        self.appSideRejectionReason = appSideRejectionReason
        self.clarificationCorrectionMode = clarificationCorrectionMode
        self.intentCoverageMode = intentCoverageMode
        self.clarificationPolicyDecision = clarificationPolicyDecision
        self.clarificationPolicyReason = clarificationPolicyReason
        self.overClarificationCorrectionAttempted = overClarificationCorrectionAttempted
        self.overClarificationCorrectionSucceeded = overClarificationCorrectionSucceeded
        self.databaseContextFactsUsed = databaseContextFactsUsed
        self.evidenceSufficientForSQL = evidenceSufficientForSQL
        self.unresolvedDecisionKinds = unresolvedDecisionKinds
        self.sqlIntentCoverageDecision = sqlIntentCoverageDecision
        self.sqlIntentCoverageReason = sqlIntentCoverageReason
        self.sqlIntentCoverageMissingSignals = sqlIntentCoverageMissingSignals
        self.sqlIntentCoverageMismatchCategory = sqlIntentCoverageMismatchCategory
        self.intentCoverageCorrectionAttempted = intentCoverageCorrectionAttempted
        self.intentCoverageCorrectionSucceeded = intentCoverageCorrectionSucceeded
    }

    private enum CodingKeys: String, CodingKey {
        case logicalTurnCount
        case terminalToolSeen
        case terminalAction
        case terminalQueryPlan
        case terminalValidationFailureReason
        case triedSchemaToolsAfterTerminal
        case producedProseInsteadOfTools
        case redundantDuplicateToolCallCount
        case redundantZeroResultSearchCount
        case redundantJoinPathCallCount
        case schemaEvidence
        case appSideRejectionReason
        case clarificationCorrectionMode
        case intentCoverageMode
        case clarificationPolicyDecision
        case clarificationPolicyReason
        case overClarificationCorrectionAttempted
        case overClarificationCorrectionSucceeded
        case databaseContextFactsUsed
        case evidenceSufficientForSQL
        case unresolvedDecisionKinds
        case sqlIntentCoverageDecision
        case sqlIntentCoverageReason
        case sqlIntentCoverageMissingSignals
        case sqlIntentCoverageMismatchCategory
        case intentCoverageCorrectionAttempted
        case intentCoverageCorrectionSucceeded
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        logicalTurnCount = try container.decodeIfPresent(Int.self, forKey: .logicalTurnCount)
        terminalToolSeen = try container.decodeIfPresent(Bool.self, forKey: .terminalToolSeen) ?? false
        terminalAction = try container.decodeIfPresent(String.self, forKey: .terminalAction)
        terminalQueryPlan = try container.decodeIfPresent(String.self, forKey: .terminalQueryPlan) ?? ""
        terminalValidationFailureReason = try container.decodeIfPresent(
            String.self,
            forKey: .terminalValidationFailureReason
        )
        triedSchemaToolsAfterTerminal = try container.decodeIfPresent(
            Bool.self,
            forKey: .triedSchemaToolsAfterTerminal
        ) ?? false
        producedProseInsteadOfTools = try container.decodeIfPresent(
            Bool.self,
            forKey: .producedProseInsteadOfTools
        ) ?? false
        redundantDuplicateToolCallCount = try container.decodeIfPresent(
            Int.self,
            forKey: .redundantDuplicateToolCallCount
        ) ?? 0
        redundantZeroResultSearchCount = try container.decodeIfPresent(
            Int.self,
            forKey: .redundantZeroResultSearchCount
        ) ?? 0
        redundantJoinPathCallCount = try container.decodeIfPresent(
            Int.self,
            forKey: .redundantJoinPathCallCount
        ) ?? 0
        schemaEvidence = try container.decodeIfPresent(
            OpenRouterSchemaToolEvidenceSummary.self,
            forKey: .schemaEvidence
        ) ?? OpenRouterSchemaToolEvidenceSummary()
        appSideRejectionReason = try container.decodeIfPresent(
            OpenRouterSchemaToolAppRejectionReason.self,
            forKey: .appSideRejectionReason
        )
        clarificationCorrectionMode = try container.decodeIfPresent(
            String.self,
            forKey: .clarificationCorrectionMode
        ) ?? ""
        intentCoverageMode = try container.decodeIfPresent(
            String.self,
            forKey: .intentCoverageMode
        ) ?? ""
        clarificationPolicyDecision = try container.decodeIfPresent(
            String.self,
            forKey: .clarificationPolicyDecision
        ) ?? ""
        clarificationPolicyReason = try container.decodeIfPresent(
            String.self,
            forKey: .clarificationPolicyReason
        ) ?? ""
        overClarificationCorrectionAttempted = try container.decodeIfPresent(
            Bool.self,
            forKey: .overClarificationCorrectionAttempted
        ) ?? false
        overClarificationCorrectionSucceeded = try container.decodeIfPresent(
            Bool.self,
            forKey: .overClarificationCorrectionSucceeded
        ) ?? false
        databaseContextFactsUsed = try container.decodeIfPresent(
            [String].self,
            forKey: .databaseContextFactsUsed
        ) ?? []
        evidenceSufficientForSQL = try container.decodeIfPresent(
            Bool.self,
            forKey: .evidenceSufficientForSQL
        ) ?? false
        unresolvedDecisionKinds = try container.decodeIfPresent(
            [String].self,
            forKey: .unresolvedDecisionKinds
        ) ?? []
        sqlIntentCoverageDecision = try container.decodeIfPresent(
            String.self,
            forKey: .sqlIntentCoverageDecision
        ) ?? ""
        sqlIntentCoverageReason = try container.decodeIfPresent(
            String.self,
            forKey: .sqlIntentCoverageReason
        ) ?? ""
        sqlIntentCoverageMissingSignals = try container.decodeIfPresent(
            [String].self,
            forKey: .sqlIntentCoverageMissingSignals
        ) ?? []
        sqlIntentCoverageMismatchCategory = try container.decodeIfPresent(
            String.self,
            forKey: .sqlIntentCoverageMismatchCategory
        ) ?? ""
        intentCoverageCorrectionAttempted = try container.decodeIfPresent(
            Bool.self,
            forKey: .intentCoverageCorrectionAttempted
        ) ?? false
        intentCoverageCorrectionSucceeded = try container.decodeIfPresent(
            Bool.self,
            forKey: .intentCoverageCorrectionSucceeded
        ) ?? false
    }
}

struct OpenRouterReportedUsage: Decodable, Equatable, Sendable {
    struct CompletionDetails: Decodable, Equatable, Sendable {
        let reasoningTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case reasoningTokens = "reasoning_tokens"
        }
    }

    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    let completionTokensDetails: CompletionDetails?
    let cost: Double?

    private enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case completionTokensDetails = "completion_tokens_details"
        case cost
    }

    var generationUsageEvent: SQLGenerationUsageEvent {
        SQLGenerationUsageEvent(
            httpAttemptCount: 0,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            reasoningTokens: completionTokensDetails?.reasoningTokens,
            totalTokens: totalTokens,
            costUSD: cost
        )
    }
}

private struct OpenRouterReportedUsageEnvelope: Decodable {
    let usage: OpenRouterReportedUsage?
}

public struct OpenRouterGenerationMetadata: Codable, Equatable, Sendable {
    public var requestedModelID: String
    public var returnedModelID: String?
    public var providerName: String?
    public var completionID: String?
    public var requestID: String?
    public var structuredOutputMode: OpenRouterStructuredOutputMode
    public var requestCount: Int
    public var retryCount: Int
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var reasoningTokens: Int?
    public var totalTokens: Int?
    public var costUSD: Double?
    public var serviceTier: String?
    public var finishReason: String?
    public var nativeFinishReason: String?
    public var agentSelectionReason: String?
    public var agentLogicalTurnCount: Int?
    public var agentHTTPAttemptCount: Int?
    public var agentSchemaToolCallCount: Int?
    public var agentInspectionToolCallCount: Int?
    public var agentTerminalOutcome: String?
    public var agentFinishReasons: [String]?
    public var agentCompletionIDs: [String]?
    public var agentRequestIDs: [String]?
    public var agentReturnedModelIDs: [String]?
    public var agentProviderNames: [String]?
    public var agentDiagnostics: OpenRouterSchemaToolAgentDiagnostics?
}

public struct OpenRouterFailureDiagnostic: Codable, Equatable, Sendable {
    public var category: OpenRouterFailure.Category
    public var httpStatus: Int?
    public var openRouterErrorType: String?
    public var providerCode: String?
    public var completionID: String?
    public var requestID: String?
    public var requestedModelID: String?
    public var returnedModelID: String?
    public var providerName: String?
    public var retryAfterSeconds: Double?
    public var suggestedWaitSeconds: Double?
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var reasoningTokens: Int?
    public var totalTokens: Int?
    public var costUSD: Double?
    public var attemptCount: Int
}

public struct OpenRouterFailure: Error, LocalizedError, Equatable, Sendable {
    public enum Category: String, Codable, CaseIterable, Equatable, Sendable {
        case authentication
        case paymentRequired
        case providerLimit
        case permissionDenied
        case guardrailBlocked
        case modelNotFound
        case modelVersionMismatch
        case invalidRequest
        case unsupportedFeature
        case contextWindow
        case maxTokensExceeded
        case rateLimited
        case providerOverloaded
        case providerUnavailable
        case timeout
        case contentPolicy
        case refusal
        case noContent
        case malformedStructuredResponse
        case networkTransport
        case serverFailure
    }

    public var category: Category
    public var message: String
    public var diagnostic: OpenRouterFailureDiagnostic

    public init(
        category: Category,
        message: String,
        httpStatus: Int? = nil,
        openRouterErrorType: String? = nil,
        providerCode: String? = nil,
        completionID: String? = nil,
        requestID: String? = nil,
        requestedModelID: String? = nil,
        returnedModelID: String? = nil,
        providerName: String? = nil,
        retryAfterSeconds: Double? = nil,
        suggestedWaitSeconds: Double? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        totalTokens: Int? = nil,
        costUSD: Double? = nil,
        attemptCount: Int = 1
    ) {
        self.category = category
        self.message = message
        self.diagnostic = OpenRouterFailureDiagnostic(
            category: category,
            httpStatus: httpStatus,
            openRouterErrorType: openRouterErrorType,
            providerCode: providerCode,
            completionID: completionID,
            requestID: requestID,
            requestedModelID: requestedModelID,
            returnedModelID: returnedModelID,
            providerName: providerName,
            retryAfterSeconds: retryAfterSeconds,
            suggestedWaitSeconds: suggestedWaitSeconds,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            reasoningTokens: reasoningTokens,
            totalTokens: totalTokens,
            costUSD: costUSD,
            attemptCount: attemptCount
        )
    }

    public var errorDescription: String? {
        "SQL generation failed: \(message)"
    }

    var pipelineCategory: TextToSQLFailureCategory {
        switch category {
        case .authentication, .paymentRequired, .providerLimit, .permissionDenied, .guardrailBlocked,
            .modelNotFound, .modelVersionMismatch:
            .backendUnavailable
        case .networkTransport, .rateLimited, .providerOverloaded, .providerUnavailable, .timeout,
            .serverFailure, .noContent:
            .transport
        case .contextWindow:
            .contextWindow
        case .malformedStructuredResponse:
            .structuredResponseParsing
        case .invalidRequest, .unsupportedFeature, .maxTokensExceeded, .contentPolicy, .refusal:
            .modelGeneration
        }
    }

    func withAttemptCount(_ count: Int) -> OpenRouterFailure {
        var copy = self
        copy.diagnostic.attemptCount = count
        return copy
    }

    func withReportedUsage(_ usage: OpenRouterReportedUsage?) -> OpenRouterFailure {
        guard let usage else { return self }
        var copy = self
        copy.diagnostic.promptTokens = usage.promptTokens
        copy.diagnostic.completionTokens = usage.completionTokens
        copy.diagnostic.reasoningTokens = usage.completionTokensDetails?.reasoningTokens
        copy.diagnostic.totalTokens = usage.totalTokens
        copy.diagnostic.costUSD = usage.cost
        return copy
    }

    static func category(
        errorType: String?,
        providerCode: String? = nil,
        httpStatus: Int?,
        message: String?
    ) -> Category {
        let code = providerCode?.lowercased()
        switch code {
        case "provider_limit", "provider_limit_exceeded", "provider_quota_exceeded":
            return .providerLimit
        case "payment_required", "insufficient_credits", "credits", "credits_exhausted":
            return .paymentRequired
        default:
            break
        }

        let type = errorType?.lowercased()
        switch type {
        case "authentication", "invalid_api_key":
            return .authentication
        case "payment_required", "insufficient_credits", "credits_exhausted":
            return .paymentRequired
        case "provider_limit", "provider_limit_exceeded", "provider_quota_exceeded":
            return .providerLimit
        case "model_not_found", "not_found":
            return .modelNotFound
        case "permission_denied":
            if (message ?? "").localizedCaseInsensitiveContains("guardrail")
                || (message ?? "").localizedCaseInsensitiveContains("blocked")
            {
                return .guardrailBlocked
            }
            return .permissionDenied
        case "guardrail_blocked":
            return .guardrailBlocked
        case "context_length_exceeded", "string_too_long":
            return .contextWindow
        case "max_tokens_exceeded", "token_limit_exceeded":
            return .maxTokensExceeded
        case "rate_limit_exceeded":
            return .rateLimited
        case "provider_overloaded":
            return .providerOverloaded
        case "provider_unavailable":
            return .providerUnavailable
        case "timeout":
            return .timeout
        case "content_policy_violation", "invalid_image", "image_too_large", "image_too_small",
            "unsupported_image_format":
            return .contentPolicy
        case "refusal":
            return .refusal
        case "invalid_request", "invalid_prompt":
            return .invalidRequest
        case "unsupported_parameter", "unsupported_feature":
            return .unsupportedFeature
        case "server", "unmapped":
            return .serverFailure
        default:
            break
        }

        if let message, OpenRouterResponseParser.isProviderOverloadMessage(message) {
            return .providerOverloaded
        }

        // OpenRouter reports an exhausted key/credit limit as a plain 403
        // message without a typed code; classify it as provider budget so
        // eval runs count it as budget-unavailable, not permission denied.
        // Gate by status: 401 stays authentication and 5xx stays retryable
        // even when a provider message mentions a limit. Effective 2xx covers
        // provider errors delivered inside HTTP-200 envelopes.
        if let message, OpenRouterResponseParser.isKeyOrCreditLimitMessage(message),
            httpStatus.map({ [402, 403, 429].contains($0) || (200...299).contains($0) }) ?? true
        {
            return .providerLimit
        }

        switch httpStatus {
        case 400:
            if let message, OpenRouterResponseParser.isContextWindowMessage(message) {
                return .contextWindow
            }
            if let message, OpenRouterResponseParser.isUnsupportedFeatureMessage(message) {
                return .unsupportedFeature
            }
            return .invalidRequest
        case 401:
            return .authentication
        case 402:
            return .paymentRequired
        case 403:
            if (message ?? "").localizedCaseInsensitiveContains("blocked")
                || (message ?? "").localizedCaseInsensitiveContains("guardrail")
            {
                return .guardrailBlocked
            }
            return .permissionDenied
        case 404:
            return .modelNotFound
        case 408:
            return .timeout
        case 413, 422:
            if let message, OpenRouterResponseParser.isContextWindowMessage(message) {
                return .contextWindow
            }
            return .invalidRequest
        case 429:
            return .rateLimited
        case 502:
            return .providerUnavailable
        case 503:
            return .providerOverloaded
        case 504:
            return .timeout
        case let status? where (500...599).contains(status):
            return .serverFailure
        default:
            return .serverFailure
        }
    }
}

extension OpenRouterFailure.Category {
    var isProviderBudgetUnavailable: Bool {
        self == .paymentRequired || self == .providerLimit
    }
}

private struct OpenRouterUsageAccumulator {
    var promptTokens: Int?
    var completionTokens: Int?
    var reasoningTokens: Int?
    var totalTokens: Int?
    var costUSD: Double?

    mutating func record(_ diagnostic: OpenRouterFailureDiagnostic) {
        Self.add(diagnostic.promptTokens, to: &promptTokens)
        Self.add(diagnostic.completionTokens, to: &completionTokens)
        Self.add(diagnostic.reasoningTokens, to: &reasoningTokens)
        Self.add(diagnostic.totalTokens, to: &totalTokens)
        Self.add(diagnostic.costUSD, to: &costUSD)
    }

    func merging(into metadata: OpenRouterGenerationMetadata) -> OpenRouterGenerationMetadata {
        var copy = metadata
        copy.promptTokens = Self.sum(promptTokens, copy.promptTokens)
        copy.completionTokens = Self.sum(completionTokens, copy.completionTokens)
        copy.reasoningTokens = Self.sum(reasoningTokens, copy.reasoningTokens)
        copy.totalTokens = Self.sum(totalTokens, copy.totalTokens)
        copy.costUSD = Self.sum(costUSD, copy.costUSD)
        return copy
    }

    func applying(to failure: OpenRouterFailure) -> OpenRouterFailure {
        var copy = failure
        copy.diagnostic.promptTokens = promptTokens
        copy.diagnostic.completionTokens = completionTokens
        copy.diagnostic.reasoningTokens = reasoningTokens
        copy.diagnostic.totalTokens = totalTokens
        copy.diagnostic.costUSD = costUSD
        return copy
    }

    private static func add(_ value: Int?, to total: inout Int?) {
        guard let value else { return }
        total = (total ?? 0) + value
    }

    private static func add(_ value: Double?, to total: inout Double?) {
        guard let value else { return }
        total = (total ?? 0) + value
    }

    private static func sum(_ first: Int?, _ second: Int?) -> Int? {
        guard first != nil || second != nil else { return nil }
        return (first ?? 0) + (second ?? 0)
    }

    private static func sum(_ first: Double?, _ second: Double?) -> Double? {
        guard first != nil || second != nil else { return nil }
        return (first ?? 0) + (second ?? 0)
    }
}

enum OpenRouterCanonicalModelValidator {
    /// True when positively-sourced catalog metadata reports a canonical
    /// version other than the pinned expectation. Shared by the preflight
    /// check and the Settings rollover warning so the two cannot drift.
    static func canonicalHasRolled(
        catalogCanonicalModelID: String?,
        capabilitySource: OpenRouterCapabilitySource,
        expectedCanonicalModelID: String?
    ) -> Bool {
        guard let expectedCanonicalModelID,
            let catalogCanonicalModelID,
            capabilitySource == .authenticatedCatalog
                || capabilitySource == .singleModelLookup
        else { return false }
        return catalogCanonicalModelID != expectedCanonicalModelID
    }

    /// Fails fast on a canonical-version rollover using already-fetched
    /// catalog metadata, before any billed completion request. Only enforced
    /// when the catalog positively reports the canonical version; stale or
    /// conservative metadata defers to the post-response check.
    static func preflight(
        catalogCanonicalModelID: String?,
        capabilitySource: OpenRouterCapabilitySource,
        expectedCanonicalModelID: String?,
        requestedModelID: String
    ) throws {
        guard canonicalHasRolled(
            catalogCanonicalModelID: catalogCanonicalModelID,
            capabilitySource: capabilitySource,
            expectedCanonicalModelID: expectedCanonicalModelID
        ) else { return }
        throw OpenRouterFailure(
            category: .modelVersionMismatch,
            message: "OpenRouter reports the fixed model now resolves to an unevaluated version. Update Widen before using this cloud model.",
            requestedModelID: requestedModelID,
            returnedModelID: catalogCanonicalModelID,
            attemptCount: 0
        )
    }

    static func validate(
        returnedModelID: String?,
        routerMetadata: OpenRouterRouterMetadata?,
        expectedCanonicalModelID: String?,
        requestedModelID: String,
        httpStatus: Int?,
        completionID: String?,
        requestID: String?,
        providerName: String?,
        attemptCount: Int
    ) throws {
        guard let expectedCanonicalModelID else { return }
        let routerEvidenceMatches = routerMetadata.map {
            $0.requested == requestedModelID
                && $0.selectedModelID == expectedCanonicalModelID
        }
        let hasConflictingRouterEvidence =
            routerMetadata != nil && routerEvidenceMatches != true
        let returnedModelMatches =
            returnedModelID == expectedCanonicalModelID
            || (returnedModelID == requestedModelID && routerEvidenceMatches == true)
        guard !hasConflictingRouterEvidence, returnedModelMatches else {
            let message =
                hasConflictingRouterEvidence
                ? "OpenRouter reported conflicting model-version metadata, so Widen cannot confirm which version served this request. Try again, and update Widen if this persists."
                : returnedModelID == nil
                    ? "OpenRouter did not report which model version served this request, so Widen cannot confirm it matches the evaluated version. Try again, and update Widen if this persists."
                    : "OpenRouter resolved the fixed model to an unevaluated version. Update Widen before using this cloud model."
            throw OpenRouterFailure(
                category: .modelVersionMismatch,
                message: message,
                httpStatus: httpStatus,
                completionID: completionID,
                requestID: requestID,
                requestedModelID: requestedModelID,
                returnedModelID: returnedModelID,
                providerName: providerName,
                attemptCount: attemptCount
            )
        }
    }
}

struct OpenRouterAPIErrorEnvelope: Decodable {
    struct APIError: Decodable {
        struct Metadata: Decodable {
            let errorType: String?
            let providerCode: String?

            private enum CodingKeys: String, CodingKey {
                case errorType = "error_type"
                case providerCode = "provider_code"
            }
        }

        let code: OpenRouterJSONValue?
        let message: String?
        let metadata: Metadata?

        var httpStatusCode: Int? {
            switch code {
            case .int(let value):
                value
            case .double(let value) where value.rounded() == value:
                Int(value)
            case .string(let value):
                Int(value)
            default:
                nil
            }
        }
    }

    let id: String?
    let model: String?
    let provider: String?
    let error: APIError?
    let openrouterMetadata: OpenRouterRouterMetadata?

    private enum CodingKeys: String, CodingKey {
        case id
        case model
        case provider
        case error
        case openrouterMetadata = "openrouter_metadata"
    }
}

enum OpenRouterJSONValue: Decodable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: OpenRouterJSONValue])
    case array([OpenRouterJSONValue])
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: OpenRouterJSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([OpenRouterJSONValue].self))
        }
    }
}

private final class OpenRouterRefreshWaiterState: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false

    func releaseOnce() -> Bool {
        lock.withLock {
            guard !released else { return false }
            released = true
            return true
        }
    }
}

actor OpenRouterModelCatalogService {
    static let shared = OpenRouterModelCatalogService()

    private struct CacheFile: Codable {
        var entries: [String: CachedCatalog]
    }

    private struct CachedCatalog: Codable {
        var fetchedAt: Date
        var models: [OpenRouterModelMetadata]
    }

    private struct CatalogResponse: Decodable {
        let data: [Model]
    }

    private struct SingleModelResponse: Decodable {
        let data: Model
    }

    private struct Model: Decodable {
        struct Provider: Decodable {
            let contextLength: Int?
            let maxCompletionTokens: Int?

            private enum CodingKeys: String, CodingKey {
                case contextLength = "context_length"
                case maxCompletionTokens = "max_completion_tokens"
            }
        }

        struct Pricing: Decodable {
            let prompt: String?
            let completion: String?
            let request: String?
            let image: String?
        }

        let id: String
        let canonicalSlug: String?
        let name: String?
        let contextLength: Int?
        let supportedParameters: [String]?
        let pricing: Pricing?
        let expirationDate: String?
        let topProvider: Provider?

        private enum CodingKeys: String, CodingKey {
            case id
            case canonicalSlug = "canonical_slug"
            case name
            case contextLength = "context_length"
            case supportedParameters = "supported_parameters"
            case pricing
            case expirationDate = "expiration_date"
            case topProvider = "top_provider"
        }

        func metadata(
            requestedID: String,
            available: Bool,
            source: OpenRouterCapabilitySource,
            fetchedAt: Date
        ) -> OpenRouterModelMetadata {
            OpenRouterModelMetadata(
                requestedID: requestedID,
                id: id,
                canonicalModelID: canonicalSlug,
                displayName: name ?? id,
                contextLength: topProvider?.contextLength ?? contextLength,
                maximumCompletionTokens: topProvider?.maxCompletionTokens,
                supportedParameters: supportedParameters ?? [],
                pricing: pricing.map {
                    OpenRouterPricing(
                        prompt: $0.prompt,
                        completion: $0.completion,
                        request: $0.request,
                        image: $0.image
                    )
                },
                expiration: expirationDate,
                isAvailableToAPIKey: available,
                capabilitySource: source,
                fetchedAt: fetchedAt
            )
        }
    }

    private let transport: any HTTPTransport
    private let baseURL: URL
    private let cacheURL: URL
    private let ttl: TimeInterval
    private let staleRetention: TimeInterval
    private var memoryCache: [String: CachedCatalog] = [:]
    private var refreshTasks: [String: Task<CachedCatalog, Error>] = [:]
    private var refreshWaiterCounts: [String: Int] = [:]

    init(
        transport: any HTTPTransport = URLSessionTransport(),
        baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!,
        cacheURL: URL? = nil,
        ttl: TimeInterval = 6 * 60 * 60,
        staleRetention: TimeInterval = 7 * 24 * 60 * 60
    ) {
        self.transport = transport
        self.baseURL = baseURL
        self.ttl = ttl
        self.staleRetention = staleRetention
        let directory =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Widen", isDirectory: true)
        self.cacheURL =
            cacheURL
            ?? directory.appendingPathComponent("openrouter-model-catalog-cache.json")
    }

    func availableModels(apiKey: String, forceRefresh: Bool = false) async throws
        -> [OpenRouterModelMetadata]
    {
        try await catalog(apiKey: apiKey, forceRefresh: forceRefresh).models
    }

    func metadata(
        apiKey: String,
        modelID: String,
        forceRefresh: Bool = false,
        allowStaleFallback: Bool = true
    ) async -> OpenRouterModelMetadata? {
        do {
            return try await lookupModel(apiKey: apiKey, modelID: modelID, forceRefresh: forceRefresh)
        } catch is CancellationError {
            return nil
        } catch {
            guard allowStaleFallback else { return nil }
            return staleCatalog(apiKey: apiKey)
                .map(staleCatalogWithSource)
                .flatMap { Self.find(modelID, in: $0.models) }
        }
    }

    /// Settings-facing lookup that rethrows the underlying catalog failure so
    /// the UI can say why metadata is unavailable, instead of a generic
    /// message. Transient failures still fall back to a stale cache entry;
    /// authentication and other non-servable failures propagate. The full
    /// catalog fetch is intentional even for a single pinned model: catalog
    /// membership is what proves the model is visible to the saved key.
    func metadataSurfacingErrors(
        apiKey: String,
        modelID: String,
        forceRefresh: Bool = false
    ) async throws -> OpenRouterModelMetadata? {
        do {
            return try await lookupModel(apiKey: apiKey, modelID: modelID, forceRefresh: forceRefresh)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if canServeStaleCatalog(after: error),
                let stale = staleCatalog(apiKey: apiKey)
                    .map(staleCatalogWithSource)
                    .flatMap({ Self.find(modelID, in: $0.models) })
            {
                return stale
            }
            throw error
        }
    }

    /// The shared model-lookup flow: fresh catalog membership first, then
    /// the single-model endpoint. Both public lookups wrap this with their
    /// distinct error handling so Settings and generation cannot drift.
    /// `metadataWithUsage` keeps a budget-gated variant of the same sequence
    /// for counted eval lookups; changes here should be mirrored there.
    private func lookupModel(
        apiKey: String,
        modelID: String,
        forceRefresh: Bool
    ) async throws -> OpenRouterModelMetadata? {
        let catalog = try await catalog(apiKey: apiKey, forceRefresh: forceRefresh)
        if let model = Self.find(modelID, in: catalog.models) {
            return model
        }
        if let single = try await fetchSingleModel(apiKey: apiKey, modelID: modelID) {
            merge(single, apiKey: apiKey)
            return single
        }
        return nil
    }

    func capabilitiesForGeneration(apiKey: String, modelID: String) async
        -> OpenRouterModelCapabilities
    {
        guard let metadata = await metadata(apiKey: apiKey, modelID: modelID) else {
            return .conservative()
        }
        return metadata.capabilities
    }

    func capabilitiesForGeneration(
        apiKey: String,
        modelID: String,
        maximumHTTPRequests: Int?
    ) async -> OpenRouterModelCapabilitiesLookup {
        let result = await metadataWithUsage(
            apiKey: apiKey,
            modelID: modelID,
            maximumHTTPRequests: maximumHTTPRequests
        )
        return OpenRouterModelCapabilitiesLookup(
            capabilities: result.metadata?.capabilities ?? .conservative(),
            httpRequestCount: result.httpRequestCount
        )
    }

    /// Resolves capabilities and enforces the pinned canonical version before
    /// a billed completion. A cache written before an app update can hold the
    /// previous canonical version for the cache TTL, so a mismatch first
    /// invalidates the cached entry and refetches once; only a mismatch
    /// against fresh metadata fails. Lookup HTTP attempts from both passes
    /// are carried in the returned lookup and on the thrown failure.
    func validatedCapabilitiesForGeneration(
        apiKey: String,
        modelID: String,
        expectedCanonicalModelID: String?,
        maximumHTTPRequests: Int?
    ) async throws -> OpenRouterModelCapabilitiesLookup {
        let lookup = await capabilitiesForGeneration(
            apiKey: apiKey,
            modelID: modelID,
            maximumHTTPRequests: maximumHTTPRequests
        )
        do {
            try OpenRouterCanonicalModelValidator.preflight(
                catalogCanonicalModelID: lookup.capabilities.canonicalModelID,
                capabilitySource: lookup.capabilities.capabilitySource,
                expectedCanonicalModelID: expectedCanonicalModelID,
                requestedModelID: modelID
            )
            return lookup
        } catch let failure as OpenRouterFailure where failure.category == .modelVersionMismatch {
            // A refetch can only observe different data when the mismatching
            // metadata came from the cache; a network-fresh mismatch is
            // authoritative. Recovering only for cache-served lookups also
            // keeps total lookup HTTP requests within the caller's budget,
            // because a cache-served first pass spent none of it.
            guard lookup.httpRequestCount == 0 else {
                throw failure.withAttemptCount(lookup.httpRequestCount)
            }
            invalidate(apiKey: apiKey, modelID: modelID)
            let refreshed = await capabilitiesForGeneration(
                apiKey: apiKey,
                modelID: modelID,
                maximumHTTPRequests: maximumHTTPRequests
            )
            do {
                try OpenRouterCanonicalModelValidator.preflight(
                    catalogCanonicalModelID: refreshed.capabilities.canonicalModelID,
                    capabilitySource: refreshed.capabilities.capabilitySource,
                    expectedCanonicalModelID: expectedCanonicalModelID,
                    requestedModelID: modelID
                )
            } catch let refreshedFailure as OpenRouterFailure {
                throw refreshed.httpRequestCount > 0
                    ? refreshedFailure.withAttemptCount(refreshed.httpRequestCount)
                    : refreshedFailure
            }
            return refreshed
        }
    }

    func invalidate(apiKey: String? = nil, modelID: String? = nil) {
        loadDiskCacheIfNeeded()
        if let apiKey {
            let key = Self.apiKeyFingerprint(apiKey)
            if modelID == nil {
                memoryCache.removeValue(forKey: key)
            } else if var cached = memoryCache[key] {
                cached.models.removeAll {
                    $0.requestedID == modelID || $0.id == modelID || $0.canonicalModelID == modelID
                }
                cached.fetchedAt = Date(timeIntervalSince1970: 0)
                memoryCache[key] = cached
            }
        } else {
            memoryCache.removeAll()
        }
        writeDiskCache()
    }

    private func catalog(apiKey: String, forceRefresh: Bool) async throws -> CachedCatalog {
        let key = Self.apiKeyFingerprint(apiKey)
        loadDiskCacheIfNeeded()
        if !forceRefresh, let cached = memoryCache[key], isFresh(cached) {
            return cached
        }
        if let task = refreshTasks[key] {
            let value = try await refreshValue(task, key: key)
            try Task.checkCancellation()
            return value
        }
        let task = Task<CachedCatalog, Error> {
            let fetched = try await fetchCatalog(apiKey: apiKey)
            store(fetched, key: key)
            return fetched
        }
        refreshTasks[key] = task
        do {
            let value = try await refreshValue(task, key: key)
            try Task.checkCancellation()
            if refreshTasks[key] == task {
                refreshTasks[key] = nil
            }
            return value
        } catch {
            if refreshTasks[key] == task {
                refreshTasks[key] = nil
            }
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            if canServeStaleCatalog(after: error), let stale = staleCatalog(apiKey: apiKey) {
                return staleCatalogWithSource(stale)
            }
            throw error
        }
    }

    private func metadataWithUsage(
        apiKey: String,
        modelID: String,
        maximumHTTPRequests: Int?
    ) async -> (metadata: OpenRouterModelMetadata?, httpRequestCount: Int) {
        var httpRequestCount = 0
        do {
            let shouldRequestCatalog = catalogLookupWillRequestHTTP(
                apiKey: apiKey,
                forceRefresh: false
            )
            if shouldRequestCatalog {
                guard maximumHTTPRequests.map({ httpRequestCount < $0 }) ?? true else {
                    return (nil, httpRequestCount)
                }
                httpRequestCount += 1
            }
            let catalog = try await catalog(apiKey: apiKey, forceRefresh: false)
            if let model = Self.find(modelID, in: catalog.models) {
                return (model, httpRequestCount)
            }
            guard maximumHTTPRequests.map({ httpRequestCount < $0 }) ?? true else {
                return (nil, httpRequestCount)
            }
            httpRequestCount += 1
            if let single = try await fetchSingleModel(apiKey: apiKey, modelID: modelID) {
                merge(single, apiKey: apiKey)
                return (single, httpRequestCount)
            }
            return (nil, httpRequestCount)
        } catch is CancellationError {
            return (nil, httpRequestCount)
        } catch {
            return (
                staleCatalog(apiKey: apiKey)
                    .map(staleCatalogWithSource)
                    .flatMap { Self.find(modelID, in: $0.models) },
                httpRequestCount
            )
        }
    }

    private func catalogLookupWillRequestHTTP(apiKey: String, forceRefresh: Bool) -> Bool {
        guard !forceRefresh else { return true }
        let key = Self.apiKeyFingerprint(apiKey)
        loadDiskCacheIfNeeded()
        guard let cached = memoryCache[key], isFresh(cached) else { return true }
        return false
    }

    private func refreshValue(
        _ task: Task<CachedCatalog, Error>,
        key: String
    ) async throws -> CachedCatalog {
        refreshWaiterCounts[key, default: 0] += 1
        let waiterState = OpenRouterRefreshWaiterState()
        defer {
            if waiterState.releaseOnce() {
                releaseRefreshWaiter(key: key, task: task, cancelIfUnused: false)
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { [waiterState] in
                if waiterState.releaseOnce() {
                    await releaseRefreshWaiter(key: key, task: task, cancelIfUnused: true)
                }
            }
        }
    }

    private func releaseRefreshWaiter(
        key: String,
        task: Task<CachedCatalog, Error>,
        cancelIfUnused: Bool
    ) {
        let remaining = max(0, (refreshWaiterCounts[key] ?? 1) - 1)
        if remaining == 0 {
            refreshWaiterCounts[key] = nil
            if cancelIfUnused {
                task.cancel()
                if refreshTasks[key] == task {
                    refreshTasks[key] = nil
                }
            }
        } else {
            refreshWaiterCounts[key] = remaining
        }
    }

    private func fetchCatalog(apiKey: String) async throws -> CachedCatalog {
        var request = URLRequest(url: baseURL.appendingPathComponent("models/user"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Widen", forHTTPHeaderField: "X-Title")
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw OpenRouterResponseParser.failure(
                from: data,
                response: response,
                requestedModelID: nil,
                attemptCount: 1
            )
        }
        let decoded = try JSONDecoder().decode(CatalogResponse.self, from: data)
        let fetchedAt = Date()
        return CachedCatalog(
            fetchedAt: fetchedAt,
            models: decoded.data.map {
                $0.metadata(
                    requestedID: $0.id,
                    available: true,
                    source: .authenticatedCatalog,
                    fetchedAt: fetchedAt
                )
            }
        )
    }

    /// A one-shot lookup for automation that bypasses Widen's catalog cache,
    /// stale fallback, and the local URL cache while requesting upstream
    /// revalidation. The public endpoint needs no spend-capable credential.
    func freshPublicModel(modelID: String) async throws -> OpenRouterModelMetadata? {
        try await fetchSingleModel(
            apiKey: nil,
            modelID: modelID,
            title: "Widen Canonical Watch",
            revalidate: true
        )
    }

    private func fetchSingleModel(
        apiKey: String?,
        modelID: String,
        title: String = "Widen",
        revalidate: Bool = false
    ) async throws
        -> OpenRouterModelMetadata?
    {
        let parts = modelID.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        var request = URLRequest(
            url: baseURL
                .appendingPathComponent("model")
                .appendingPathComponent(parts[0])
                .appendingPathComponent(parts[1])
        )
        if revalidate {
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        }
        request.httpMethod = "GET"
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(title, forHTTPHeaderField: "X-Title")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 404 { return nil }
            throw OpenRouterResponseParser.failure(
                from: data,
                response: response,
                requestedModelID: modelID,
                attemptCount: 1
            )
        }
        let decoded = try JSONDecoder().decode(SingleModelResponse.self, from: data)
        let fetchedAt = Date()
        return decoded.data.metadata(
            requestedID: modelID,
            available: false,
            source: .singleModelLookup,
            fetchedAt: fetchedAt
        )
    }

    private func merge(_ metadata: OpenRouterModelMetadata, apiKey: String) {
        let key = Self.apiKeyFingerprint(apiKey)
        var cached = memoryCache[key] ?? CachedCatalog(fetchedAt: Date(), models: [])
        let matchingIDs = Set([metadata.requestedID, metadata.id, metadata.canonicalModelID].compactMap { $0 })
        cached.models.removeAll {
            matchingIDs.contains($0.requestedID)
                || matchingIDs.contains($0.id)
                || $0.canonicalModelID.map(matchingIDs.contains) == true
        }
        cached.models.append(metadata)
        memoryCache[key] = cached
        writeDiskCache()
    }

    private func store(_ catalog: CachedCatalog, key: String) {
        memoryCache[key] = catalog
        writeDiskCache()
    }

    private func staleCatalog(apiKey: String) -> CachedCatalog? {
        loadDiskCacheIfNeeded()
        let key = Self.apiKeyFingerprint(apiKey)
        guard let cached = memoryCache[key] else { return nil }
        guard Date().timeIntervalSince(cached.fetchedAt) <= staleRetention else { return nil }
        return cached
    }

    private func staleCatalogWithSource(_ catalog: CachedCatalog) -> CachedCatalog {
        CachedCatalog(
            fetchedAt: catalog.fetchedAt,
            models: catalog.models.map { model in
                var copy = model
                copy.capabilitySource = .staleCache
                return copy
            }
        )
    }

    private func canServeStaleCatalog(after error: any Error) -> Bool {
        if let failure = error as? OpenRouterFailure {
            switch failure.category {
            case .rateLimited, .providerOverloaded, .providerUnavailable, .timeout,
                .networkTransport, .serverFailure:
                return true
            case .authentication, .paymentRequired, .providerLimit, .permissionDenied,
                .guardrailBlocked, .modelNotFound, .modelVersionMismatch, .invalidRequest,
                .unsupportedFeature, .contextWindow, .maxTokensExceeded, .contentPolicy, .refusal, .noContent,
                .malformedStructuredResponse:
                return false
            }
        }
        if let urlError = error as? URLError {
            return urlError.code != .cancelled
        }
        return false
    }

    private func isFresh(_ catalog: CachedCatalog) -> Bool {
        Date().timeIntervalSince(catalog.fetchedAt) <= ttl
    }

    private func loadDiskCacheIfNeeded() {
        guard memoryCache.isEmpty else { return }
        guard let data = try? Data(contentsOf: cacheURL),
            let decoded = try? JSONDecoder.widenOpenRouter.decode(CacheFile.self, from: data)
        else { return }
        memoryCache = decoded.entries.filter {
            Date().timeIntervalSince($0.value.fetchedAt) <= staleRetention
        }
    }

    private func writeDiskCache() {
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.widenOpenRouter.encode(CacheFile(entries: memoryCache))
            try data.write(to: cacheURL, options: [.atomic])
        } catch {
            // Cache failures must not break generation.
        }
    }

    private static func find(_ id: String, in models: [OpenRouterModelMetadata])
        -> OpenRouterModelMetadata?
    {
        models.first {
            $0.requestedID == id || $0.id == id || $0.canonicalModelID == id
        }
    }

    static func apiKeyFingerprint(_ apiKey: String) -> String {
        SHA256.hash(data: Data(apiKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The only writer of the request `provider` block: every OpenRouter
/// completion demands endpoints with zero data retention, no provider data
/// collection, and full request-parameter support.
struct OpenRouterProviderPreferences: Equatable, Sendable {
    static let requiredPrivateRouting = OpenRouterProviderPreferences()

    let requireParameters = true
    let zdr = true
    let dataCollection = "deny"

    func apply(to body: inout [String: Any]) {
        body["provider"] = [
            "require_parameters": requireParameters,
            "zdr": zdr,
            "data_collection": dataCollection,
        ]
    }
}

struct OpenRouterRequestBuilder: Sendable {
    static let completionTokenBudget = 2_048
    let endpoint: URL

    init(endpoint: URL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!) {
        self.endpoint = endpoint
    }

    struct BuiltRequest: Sendable {
        var request: URLRequest
        var mode: OpenRouterStructuredOutputMode
    }

    func build(
        apiKey: String,
        model: String,
        instructions: String,
        prompt: String,
        capabilities: OpenRouterModelCapabilities
    ) throws -> BuiltRequest {
        let mode: OpenRouterStructuredOutputMode =
            capabilities.supportsStructuredOutputs ? .strictJSONSchema : .promptOnlyJSON
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": prompt],
            ],
            "stream": false,
        ]
        if capabilities.supportsTemperature {
            body["temperature"] = 0
        }
        if capabilities.supportsMaxCompletionTokens {
            body["max_completion_tokens"] = cappedCompletionTokens(capabilities)
        } else if capabilities.supportsMaxTokens {
            body["max_tokens"] = cappedCompletionTokens(capabilities)
        } else if mode == .promptOnlyJSON {
            body["max_tokens"] = Self.completionTokenBudget
        }
        if mode == .strictJSONSchema {
            body["response_format"] = Self.responseFormat()
        }
        OpenRouterProviderPreferences.requiredPrivateRouting.apply(to: &body)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Widen", forHTTPHeaderField: "X-Title")
        request.setValue("enabled", forHTTPHeaderField: "X-OpenRouter-Metadata")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return BuiltRequest(request: request, mode: mode)
    }

    func buildTinyJSONTest(
        apiKey: String,
        model: String,
        capabilities: OpenRouterModelCapabilities
    ) throws -> BuiltRequest {
        try build(
            apiKey: apiKey,
            model: model,
            instructions: """
                Respond with a single JSON object and nothing else, using exactly these keys:
                {"sql": string, "explanation": string, "assumptions": [string], "referencedTables": [string], "confidence": number between 0 and 1, "riskLevel": "low" or "medium" or "high", "needsClarification": boolean, "clarificationQuestion": string or null}
                """,
            prompt: """
                Return a minimal connectivity response for SELECT 1.
                """,
            capabilities: capabilities
        )
    }

    private func cappedCompletionTokens(_ capabilities: OpenRouterModelCapabilities) -> Int {
        min(Self.completionTokenBudget, max(16, capabilities.maximumCompletionTokens ?? Self.completionTokenBudget))
    }

    private static func responseFormat() -> [String: Any] {
        [
            "type": "json_schema",
            "json_schema": [
                "name": "generated_sql",
                "strict": true,
                "schema": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": [
                        "sql", "explanation", "assumptions", "referencedTables",
                        "confidence", "riskLevel", "needsClarification", "clarificationQuestion",
                    ],
                    "properties": [
                        "sql": ["type": "string"],
                        "explanation": ["type": "string"],
                        "assumptions": ["type": "array", "items": ["type": "string"]],
                        "referencedTables": ["type": "array", "items": ["type": "string"]],
                        "confidence": ["type": "number"],
                        "riskLevel": ["type": "string", "enum": ["low", "medium", "high"]],
                        "needsClarification": ["type": "boolean"],
                        "clarificationQuestion": ["type": ["string", "null"]],
                    ],
                ],
            ],
        ]
    }
}

struct OpenRouterRetryPolicy: Sendable {
    static let defaultMaxAttempts = 3
    static let retryAfterCap: TimeInterval = 15

    var maxAttempts: Int

    init(maxAttempts: Int = Self.defaultMaxAttempts) {
        self.maxAttempts = max(1, maxAttempts)
    }

    func retryDelay(
        for failure: OpenRouterFailure,
        attempt: Int,
        noContentRetries: Int
    ) -> TimeInterval? {
        guard attempt < maxAttempts else { return nil }
        if failure.category == .noContent, noContentRetries >= 1 { return nil }
        guard isRetryable(failure.category) else { return nil }
        if let retryAfter = failure.diagnostic.retryAfterSeconds {
            guard retryAfter <= Self.retryAfterCap else { return nil }
            return max(0, retryAfter)
        }
        let base = attempt == 1 ? 0.5 : 1.0
        let jitter = Double.random(in: 0...0.15)
        return base + jitter
    }

    func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return seconds
        }
        if let date = Self.httpDateFormatter.date(from: value) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }

    private func isRetryable(_ category: OpenRouterFailure.Category) -> Bool {
        switch category {
        case .rateLimited, .providerOverloaded, .providerUnavailable, .timeout, .networkTransport,
            .serverFailure, .noContent:
            true
        case .authentication, .paymentRequired, .providerLimit, .permissionDenied, .guardrailBlocked,
            .modelNotFound, .modelVersionMismatch, .invalidRequest, .unsupportedFeature, .contextWindow,
            .maxTokensExceeded, .contentPolicy, .refusal, .malformedStructuredResponse:
            false
        }
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter
    }()
}

struct OpenRouterResponseParser: Sendable {
    struct ParsedResult: Sendable {
        var result: SQLGenerationResult
        var metadata: OpenRouterGenerationMetadata
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let role: String?
                let content: MessageContent?
                let refusal: String?
            }

            let index: Int?
            let message: Message?
            let finishReason: String?
            let nativeFinishReason: String?
            let error: OpenRouterAPIErrorEnvelope.APIError?

            private enum CodingKeys: String, CodingKey {
                case index
                case message
                case finishReason = "finish_reason"
                case nativeFinishReason = "native_finish_reason"
                case error
            }
        }

        let id: String?
        let model: String?
        let provider: String?
        let serviceTier: String?
        let choices: [Choice]
        let usage: OpenRouterReportedUsage?
        let error: OpenRouterAPIErrorEnvelope.APIError?
        let openrouterMetadata: OpenRouterRouterMetadata?

        private enum CodingKeys: String, CodingKey {
            case id
            case model
            case provider
            case serviceTier = "service_tier"
            case choices
            case usage
            case error
            case openrouterMetadata = "openrouter_metadata"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            provider = try container.decodeIfPresent(String.self, forKey: .provider)
            serviceTier = try container.decodeIfPresent(String.self, forKey: .serviceTier)
            choices = try container.decodeIfPresent([Choice].self, forKey: .choices) ?? []
            usage = try container.decodeIfPresent(OpenRouterReportedUsage.self, forKey: .usage)
            error = try container.decodeIfPresent(OpenRouterAPIErrorEnvelope.APIError.self, forKey: .error)
            openrouterMetadata = try container.decodeIfPresent(
                OpenRouterRouterMetadata.self,
                forKey: .openrouterMetadata
            )
        }
    }

    private enum MessageContent: Decodable {
        struct Part: Decodable {
            let type: String?
            let text: String?
        }

        case string(String)
        case parts([Part])

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                self = .string(string)
            } else {
                self = .parts(try container.decode([Part].self))
            }
        }

        var text: String {
            switch self {
            case .string(let value):
                value
            case .parts(let parts):
                parts.compactMap { part in
                    guard part.type == nil || part.type == "text" || part.type == "output_text" else {
                        return nil
                    }
                    return part.text
                }.joined()
            }
        }
    }

    private struct CloudGeneratedSQLResponse: Decodable {
        let sql: String
        let explanation: String?
        let assumptions: [String]?
        let referencedTables: [String]?
        let confidence: Double?
        let riskLevel: String?
        let needsClarification: Bool?
        let clarificationQuestion: String?
    }

    func parse(
        data: Data,
        response: HTTPURLResponse,
        requestedModelID: String,
        mode: OpenRouterStructuredOutputMode,
        requestCount: Int,
        retryCount: Int,
        expectedCanonicalModelID: String? = nil
    ) throws -> ParsedResult {
        let reportedUsage = Self.reportedUsage(from: data)
        if !(200..<300).contains(response.statusCode) {
            throw Self.failure(
                from: data,
                response: response,
                requestedModelID: requestedModelID,
                attemptCount: requestCount
            ).withReportedUsage(reportedUsage)
        }
        let requestID = response.value(forHTTPHeaderField: "X-Request-Id")
            ?? response.value(forHTTPHeaderField: "X-Request-ID")
            ?? response.value(forHTTPHeaderField: "X-Generation-Id")
        let completion: ChatResponse
        do {
            completion = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw OpenRouterFailure(
                category: .malformedStructuredResponse,
                message: "OpenRouter returned a malformed response envelope.",
                httpStatus: response.statusCode,
                requestID: requestID,
                requestedModelID: requestedModelID,
                attemptCount: requestCount
            ).withReportedUsage(reportedUsage)
        }
        if let topError = completion.error {
            throw Self.failure(
                apiError: topError,
                httpStatus: response.statusCode,
                completionID: completion.id,
                requestID: requestID,
                requestedModelID: requestedModelID,
                returnedModelID: completion.model,
                providerName: completion.provider ?? completion.openrouterMetadata?.selectedProvider,
                attemptCount: requestCount
            ).withReportedUsage(reportedUsage)
        }
        guard let choice = completion.choices.first else {
            throw OpenRouterFailure(
                category: .noContent,
                message: "OpenRouter returned no choices.",
                httpStatus: response.statusCode,
                completionID: completion.id,
                requestID: requestID,
                requestedModelID: requestedModelID,
                returnedModelID: completion.model,
                providerName: completion.provider ?? completion.openrouterMetadata?.selectedProvider,
                attemptCount: requestCount
            ).withReportedUsage(reportedUsage)
        }
        if let choiceError = choice.error {
            throw Self.failure(
                apiError: choiceError,
                httpStatus: response.statusCode,
                completionID: completion.id,
                requestID: requestID,
                requestedModelID: requestedModelID,
                returnedModelID: completion.model,
                providerName: completion.provider ?? completion.openrouterMetadata?.selectedProvider,
                attemptCount: requestCount
            ).withReportedUsage(reportedUsage)
        }
        if choice.finishReason == "error" {
            throw OpenRouterFailure(
                category: .providerUnavailable,
                message: "The provider ended generation with an error.",
                httpStatus: response.statusCode,
                completionID: completion.id,
                requestID: requestID,
                requestedModelID: requestedModelID,
                returnedModelID: completion.model,
                providerName: completion.provider ?? completion.openrouterMetadata?.selectedProvider,
                attemptCount: requestCount
            ).withReportedUsage(reportedUsage)
        }
        if choice.finishReason == "length" {
            throw OpenRouterFailure(
                category: .maxTokensExceeded,
                message: "The provider stopped because the completion token limit was reached.",
                httpStatus: response.statusCode,
                completionID: completion.id,
                requestID: requestID,
                requestedModelID: requestedModelID,
                returnedModelID: completion.model,
                providerName: completion.provider ?? completion.openrouterMetadata?.selectedProvider,
                attemptCount: requestCount
            ).withReportedUsage(reportedUsage)
        }
        if choice.finishReason == "content_filter" {
            throw OpenRouterFailure(
                category: .contentPolicy,
                message: "The provider stopped because of a content policy filter.",
                httpStatus: response.statusCode,
                completionID: completion.id,
                requestID: requestID,
                requestedModelID: requestedModelID,
                returnedModelID: completion.model,
                providerName: completion.provider ?? completion.openrouterMetadata?.selectedProvider,
                attemptCount: requestCount
            ).withReportedUsage(reportedUsage)
        }
        if let refusal = choice.message?.refusal, !refusal.isEmpty {
            throw OpenRouterFailure(
                category: .refusal,
                message: "The provider refused the request.",
                httpStatus: response.statusCode,
                completionID: completion.id,
                requestID: requestID,
                requestedModelID: requestedModelID,
                returnedModelID: completion.model,
                providerName: completion.provider ?? completion.openrouterMetadata?.selectedProvider,
                attemptCount: requestCount
            ).withReportedUsage(reportedUsage)
        }
        guard let content = choice.message?.content?.text
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !content.isEmpty
        else {
            throw OpenRouterFailure(
                category: .noContent,
                message: "OpenRouter returned empty assistant content.",
                httpStatus: response.statusCode,
                completionID: completion.id,
                requestID: requestID,
                requestedModelID: requestedModelID,
                returnedModelID: completion.model,
                providerName: completion.provider ?? completion.openrouterMetadata?.selectedProvider,
                attemptCount: requestCount
            ).withReportedUsage(reportedUsage)
        }
        do {
            try OpenRouterCanonicalModelValidator.validate(
                returnedModelID: completion.model,
                routerMetadata: completion.openrouterMetadata,
                expectedCanonicalModelID: expectedCanonicalModelID,
                requestedModelID: requestedModelID,
                httpStatus: response.statusCode,
                completionID: completion.id,
                requestID: requestID,
                providerName: completion.provider ?? completion.openrouterMetadata?.selectedProvider,
                attemptCount: requestCount
            )
        } catch let failure as OpenRouterFailure {
            throw failure.withReportedUsage(reportedUsage)
        }
        let objectData: Data
        switch mode {
        case .strictJSONSchema:
            objectData = Data(content.utf8)
        case .promptOnlyJSON:
            guard let data = Self.promptOnlyJSONObjectData(from: content) else {
                throw OpenRouterFailure(
                    category: .malformedStructuredResponse,
                    message: "The cloud model did not return a JSON object.",
                    httpStatus: response.statusCode,
                    completionID: completion.id,
                    requestID: requestID,
                    requestedModelID: requestedModelID,
                    returnedModelID: completion.model,
                    providerName: completion.provider ?? completion.openrouterMetadata?.selectedProvider,
                    attemptCount: requestCount
                ).withReportedUsage(reportedUsage)
            }
            objectData = data
        }

        let generated: CloudGeneratedSQLResponse
        do {
            generated = try JSONDecoder().decode(CloudGeneratedSQLResponse.self, from: objectData)
        } catch {
            throw OpenRouterFailure(
                category: .malformedStructuredResponse,
                message: "The cloud model returned malformed structured JSON.",
                httpStatus: response.statusCode,
                completionID: completion.id,
                requestID: requestID,
                requestedModelID: requestedModelID,
                returnedModelID: completion.model,
                providerName: completion.provider ?? completion.openrouterMetadata?.selectedProvider,
                attemptCount: requestCount
            ).withReportedUsage(reportedUsage)
        }

        let needsClarification = generated.needsClarification ?? false
        let sql = generated.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let clarificationQuestion = generated.clarificationQuestion?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard needsClarification || !sql.isEmpty else {
            throw OpenRouterFailure(
                category: .malformedStructuredResponse,
                message: "The cloud model returned empty SQL without a clarification.",
                httpStatus: response.statusCode,
                completionID: completion.id,
                requestID: requestID,
                requestedModelID: requestedModelID,
                returnedModelID: completion.model,
                providerName: completion.provider ?? completion.openrouterMetadata?.selectedProvider,
                attemptCount: requestCount
            ).withReportedUsage(reportedUsage)
        }
        guard !needsClarification || clarificationQuestion?.isEmpty == false else {
            throw OpenRouterFailure(
                category: .malformedStructuredResponse,
                message: "The cloud model requested clarification without a question.",
                httpStatus: response.statusCode,
                completionID: completion.id,
                requestID: requestID,
                requestedModelID: requestedModelID,
                returnedModelID: completion.model,
                providerName: completion.provider ?? completion.openrouterMetadata?.selectedProvider,
                attemptCount: requestCount
            ).withReportedUsage(reportedUsage)
        }

        let metadata = OpenRouterGenerationMetadata(
            requestedModelID: requestedModelID,
            returnedModelID: completion.model,
            providerName: completion.provider ?? completion.openrouterMetadata?.selectedProvider,
            completionID: completion.id,
            requestID: requestID,
            structuredOutputMode: mode,
            requestCount: requestCount,
            retryCount: retryCount,
            promptTokens: completion.usage?.promptTokens,
            completionTokens: completion.usage?.completionTokens,
            reasoningTokens: completion.usage?.completionTokensDetails?.reasoningTokens,
            totalTokens: completion.usage?.totalTokens,
            costUSD: completion.usage?.cost,
            serviceTier: completion.serviceTier,
            finishReason: choice.finishReason,
            nativeFinishReason: choice.nativeFinishReason
        )
        var result = SQLGenerationResult(
            sql: needsClarification ? "" : sql,
            explanation: generated.explanation ?? "",
            assumptions: generated.assumptions ?? [],
            referencedTables: generated.referencedTables ?? [],
            confidence: min(max(generated.confidence ?? 0.5, 0), 1),
            riskLevel: SQLRiskLevel(rawValue: (generated.riskLevel ?? "").lowercased()) ?? .medium,
            needsClarification: needsClarification,
            clarificationQuestion: clarificationQuestion,
            backendMetadata: metadata
        )
        result.backendMetadata = metadata
        return ParsedResult(result: result, metadata: metadata)
    }

    static func reportedUsage(from data: Data) -> OpenRouterReportedUsage? {
        guard let envelope = try? JSONDecoder().decode(
            OpenRouterReportedUsageEnvelope.self,
            from: data
        ) else { return nil }
        return envelope.usage
    }

    static func failure(
        from data: Data,
        response: HTTPURLResponse,
        requestedModelID: String?,
        attemptCount: Int,
        retryAfterSeconds: Double? = nil
    ) -> OpenRouterFailure {
        let requestID = response.value(forHTTPHeaderField: "X-Request-Id")
            ?? response.value(forHTTPHeaderField: "X-Request-ID")
            ?? response.value(forHTTPHeaderField: "X-Generation-Id")
        if let envelope = try? JSONDecoder().decode(OpenRouterAPIErrorEnvelope.self, from: data),
            let apiError = envelope.error
        {
            let effectiveHTTPStatus = apiError.httpStatusCode ?? response.statusCode
            var failure = self.failure(
                apiError: apiError,
                httpStatus: effectiveHTTPStatus,
                completionID: envelope.id,
                requestID: requestID,
                requestedModelID: requestedModelID ?? envelope.openrouterMetadata?.requested,
                returnedModelID: envelope.model,
                providerName: envelope.provider ?? envelope.openrouterMetadata?.selectedProvider,
                attemptCount: attemptCount
            )
            failure.diagnostic.retryAfterSeconds = retryAfterSeconds
            return failure
        }
        let message = HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        return OpenRouterFailure(
            category: OpenRouterFailure.category(
                errorType: nil,
                providerCode: nil,
                httpStatus: response.statusCode,
                message: message
            ),
            message: "OpenRouter returned HTTP \(response.statusCode).",
            httpStatus: response.statusCode,
            requestID: requestID,
            requestedModelID: requestedModelID,
            retryAfterSeconds: retryAfterSeconds,
            attemptCount: attemptCount
        )
    }

    static func failure(
        apiError: OpenRouterAPIErrorEnvelope.APIError,
        httpStatus: Int?,
        completionID: String?,
        requestID: String?,
        requestedModelID: String?,
        returnedModelID: String?,
        providerName: String?,
        attemptCount: Int
    ) -> OpenRouterFailure {
        let message = apiError.message ?? "OpenRouter returned an error."
        let effectiveHTTPStatus = apiError.httpStatusCode ?? httpStatus
        var displayMessage = safeMessage(message)
        if isProviderRoutingPolicyMessage(message) {
            displayMessage =
                "No OpenRouter endpoint met Widen's private-routing requirements for this model. Widen requires zero data retention, no provider data collection, and full request-parameter support, and fails closed rather than relaxing them. \(displayMessage)"
        }
        return OpenRouterFailure(
            category: OpenRouterFailure.category(
                errorType: apiError.metadata?.errorType,
                providerCode: apiError.metadata?.providerCode,
                httpStatus: effectiveHTTPStatus,
                message: message
            ),
            message: displayMessage,
            httpStatus: effectiveHTTPStatus,
            openRouterErrorType: apiError.metadata?.errorType,
            providerCode: apiError.metadata?.providerCode,
            completionID: completionID,
            requestID: requestID,
            requestedModelID: requestedModelID,
            returnedModelID: returnedModelID,
            providerName: providerName,
            attemptCount: attemptCount
        )
    }

    static func promptOnlyJSONObjectData(from content: String) -> Data? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            return Data(trimmed.utf8)
        }
        if let fenced = fencedJSONObjectData(from: trimmed) {
            return fenced
        }
        if let start = trimmed.firstIndex(of: "{"),
            let end = trimmed.lastIndex(of: "}"),
            start < end
        {
            return Data(trimmed[start...end].utf8)
        }
        return nil
    }

    private static func fencedJSONObjectData(from content: String) -> Data? {
        let lines = content.components(separatedBy: .newlines)
        var index = lines.startIndex
        while index < lines.endIndex {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("```") else {
                index = lines.index(after: index)
                continue
            }

            var closing = lines.index(after: index)
            while closing < lines.endIndex {
                if lines[closing].trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
                    let body = lines[lines.index(after: index)..<closing]
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if body.hasPrefix("{"), body.hasSuffix("}") {
                        return Data(body.utf8)
                    }
                    break
                }
                closing = lines.index(after: closing)
            }
            index = closing < lines.endIndex ? lines.index(after: closing) : lines.endIndex
        }
        return nil
    }

    /// OpenRouter routing failures for provider data-policy preferences (ZDR,
    /// data collection) arrive as generic 404/503 messages; detect them so
    /// the user sees why generation failed closed. Keep the match specific to
    /// data-policy wording — generic "no endpoints" messages also cover model
    /// delisting and provider outages, which are not privacy failures.
    static func isProviderRoutingPolicyMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("data policy")
            || lower.contains("data collection")
            || lower.contains("zero data retention")
            || lower.contains("zdr")
            // require_parameters is the third enforced routing preference;
            // its rejections are worded around unsupported parameters.
            || lower.contains("requested parameters")
    }

    /// OpenRouter reports an exhausted key/credit limit as plain message text
    /// without a typed code; detect it so eval runs count it as
    /// budget-unavailable rather than permission denied.
    static func isKeyOrCreditLimitMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("key limit exceeded")
            || lower.contains("credit limit")
            || lower.contains("insufficient credits")
            || lower.contains("spend limit")
    }

    static func isContextWindowMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("context window")
            || lower.contains("context length")
            || lower.contains("maximum context")
            || lower.contains("context_length")
            || lower.contains("prompt is too long")
            || lower.contains("too many tokens")
            || lower.contains("token limit")
    }

    static func isUnsupportedFeatureMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("response_format")
            || lower.contains("json_schema")
            || lower.contains("structured output")
            || lower.contains("unsupported parameter")
            || lower.contains("not supported")
    }

    static func isProviderOverloadMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("high demand")
            || lower.contains("peak load")
            || lower.contains("provider overloaded")
            || lower.contains("temporarily overloaded")
            || lower.contains("capacity")
            || lower.contains("provisioned throughput")
    }

    private static func safeMessage(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "OpenRouter returned an error." }
        return String(trimmed.prefix(240))
    }
}

struct OpenRouterRouterMetadata: Decodable, Equatable, Sendable {
    struct Endpoints: Decodable, Equatable, Sendable {
        struct Endpoint: Decodable, Equatable, Sendable {
            let provider: String?
            let model: String?
            let selected: Bool?
        }

        let available: [Endpoint]?
    }

    let requested: String?
    let summary: String?
    let attempt: Int?
    let endpoints: Endpoints?

    private var selectedEndpoint: Endpoints.Endpoint? {
        guard let selected = endpoints?.available?.filter({ $0.selected == true }),
            selected.count == 1
        else { return nil }
        return selected[0]
    }

    var selectedProvider: String? {
        selectedEndpoint?.provider
    }

    var selectedModelID: String? {
        selectedEndpoint?.model
    }
}

struct OpenRouterConnectivityCheck: Sendable {
    struct Result: Equatable, Sendable {
        var keyAccepted: Bool
        var selectedModelAvailable: Bool
        var capabilities: OpenRouterModelCapabilities
        var returnedModelID: String?
        var providerName: String?
        var latencyMs: Int
        var retryCount: Int
        var error: OpenRouterFailure?
    }

    let apiKey: String
    let model: String
    let expectedCanonicalModelID: String?
    let catalogService: OpenRouterModelCatalogService
    let transport: any HTTPTransport
    let requestBuilder: OpenRouterRequestBuilder

    init(
        apiKey: String,
        model: String,
        expectedCanonicalModelID: String?,
        catalogService: OpenRouterModelCatalogService = .shared,
        transport: any HTTPTransport = URLSessionTransport(),
        requestBuilder: OpenRouterRequestBuilder = OpenRouterRequestBuilder()
    ) {
        self.apiKey = apiKey
        self.model = model
        self.expectedCanonicalModelID = expectedCanonicalModelID
        self.catalogService = catalogService
        self.transport = transport
        self.requestBuilder = requestBuilder
    }

    func run() async -> Result {
        let started = Date()
        do {
            let metadata = try await catalogService.metadataSurfacingErrors(
                apiKey: apiKey,
                modelID: model,
                forceRefresh: true
            )
            let capabilities = metadata?.capabilities ?? .conservative()
            try OpenRouterCanonicalModelValidator.preflight(
                catalogCanonicalModelID: capabilities.canonicalModelID,
                capabilitySource: capabilities.capabilitySource,
                expectedCanonicalModelID: expectedCanonicalModelID,
                requestedModelID: model
            )
            let generator = OpenRouterSQLGenerator(
                apiKey: apiKey,
                model: model,
                expectedCanonicalModelID: expectedCanonicalModelID,
                transport: transport,
                catalogService: catalogService,
                requestBuilder: requestBuilder
            )
            let parsed = try await generator.testTinyCompletion(capabilities: capabilities)
            return Result(
                keyAccepted: true,
                selectedModelAvailable: true,
                capabilities: capabilities,
                returnedModelID: parsed.returnedModelID,
                providerName: parsed.providerName,
                latencyMs: elapsedMilliseconds(since: started),
                retryCount: parsed.retryCount,
                error: nil
            )
        } catch let failure as OpenRouterFailure {
            return Result(
                keyAccepted: failure.category != .authentication,
                selectedModelAvailable: failure.category != .modelNotFound
                    && failure.category != .modelVersionMismatch,
                capabilities: .conservative(),
                returnedModelID: failure.diagnostic.returnedModelID,
                providerName: failure.diagnostic.providerName,
                latencyMs: elapsedMilliseconds(since: started),
                retryCount: max(0, failure.diagnostic.attemptCount - 1),
                error: failure
            )
        } catch {
            let failure = OpenRouterFailure(
                category: .networkTransport,
                message: error.localizedDescription,
                requestedModelID: model
            )
            return Result(
                keyAccepted: true,
                selectedModelAvailable: false,
                capabilities: .conservative(),
                returnedModelID: nil,
                providerName: nil,
                latencyMs: elapsedMilliseconds(since: started),
                retryCount: 0,
                error: failure
            )
        }
    }
}

/// Generates SQL with a hosted model through OpenRouter's OpenAI-compatible
/// chat-completions API. It keeps the same SQL prompts as the local model, but
/// chooses the transport mode from authenticated OpenRouter capabilities.
public final class OpenRouterSQLGenerator: SQLGenerator, Sendable {
    static let schemaCharacterBudget = 60_000

    private let apiKey: String
    let model: String
    let expectedCanonicalModelID: String?
    private let transport: any HTTPTransport
    private let catalogService: OpenRouterModelCatalogService
    private let requestBuilder: OpenRouterRequestBuilder
    private let parser = OpenRouterResponseParser()
    private let retryPolicy: OpenRouterRetryPolicy
    private let countCapabilityLookupHTTPAttempts: Bool
    private let preResolvedCapabilities: OpenRouterModelCapabilities?

    public init(
        apiKey: String,
        model: String,
        expectedCanonicalModelID: String?,
        transport: any HTTPTransport = URLSessionTransport(),
        endpoint: URL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
        maximumHTTPAttempts: Int = 3,
        countCapabilityLookupHTTPAttempts: Bool = false
    ) {
        self.apiKey = apiKey
        self.model = model
        self.expectedCanonicalModelID = expectedCanonicalModelID
        self.transport = transport
        self.catalogService = .shared
        self.requestBuilder = OpenRouterRequestBuilder(endpoint: endpoint)
        self.retryPolicy = OpenRouterRetryPolicy(maxAttempts: maximumHTTPAttempts)
        self.countCapabilityLookupHTTPAttempts = countCapabilityLookupHTTPAttempts
        self.preResolvedCapabilities = nil
    }

    init(
        apiKey: String,
        model: String,
        expectedCanonicalModelID: String?,
        transport: any HTTPTransport,
        catalogService: OpenRouterModelCatalogService,
        requestBuilder: OpenRouterRequestBuilder,
        retryPolicy: OpenRouterRetryPolicy = OpenRouterRetryPolicy(),
        countCapabilityLookupHTTPAttempts: Bool = false,
        preResolvedCapabilities: OpenRouterModelCapabilities? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        self.expectedCanonicalModelID = expectedCanonicalModelID
        self.transport = transport
        self.catalogService = catalogService
        self.requestBuilder = requestBuilder
        self.retryPolicy = retryPolicy
        self.countCapabilityLookupHTTPAttempts = countCapabilityLookupHTTPAttempts
        self.preResolvedCapabilities = preResolvedCapabilities
    }

    public func generateSQL(
        question: String,
        schema: DatabaseSchema,
        context: SQLGenerationContext,
        config: SQLGenerationConfig
    ) async throws -> SQLGenerationResult {
        let instructions =
            SQLPromptBuilder.instructions(defaultRowLimit: config.defaultRowLimit)
            + "\n\n" + Self.jsonInstructions
        let bundle = SQLPromptBuilder.promptBundle(
            question: question,
            schema: schema,
            context: context,
            databaseContext: config.databaseContext,
            maxSchemaCharacters: Self.schemaCharacterBudget
        )
        let prompt = bundle.prompt
        let started = Date()
        let availableHTTPAttempts = countCapabilityLookupHTTPAttempts
            ? OpenRouterHTTPAttemptBudget.remaining(
                maximumHTTPAttempts: retryPolicy.maxAttempts,
                contextModelCallCount: context.modelCallCount
            )
            : retryPolicy.maxAttempts
        guard availableHTTPAttempts > 0 else {
            throw OpenRouterHTTPAttemptBudgetExhausted(
                message: "OpenRouter HTTP-attempt budget exhausted before generation."
            )
        }
        let capabilityLookupHTTPAttempts: Int
        let capabilities: OpenRouterModelCapabilities
        if let preResolvedCapabilities {
            // Pre-resolved capabilities were already validated by the caller:
            // the schema-tool agent's legacy fallback passes capabilities it
            // resolved through validatedCapabilitiesForGeneration.
            capabilityLookupHTTPAttempts = 0
            capabilities = preResolvedCapabilities
        } else if countCapabilityLookupHTTPAttempts {
            let lookup = try await catalogService.validatedCapabilitiesForGeneration(
                apiKey: apiKey,
                modelID: model,
                expectedCanonicalModelID: expectedCanonicalModelID,
                maximumHTTPRequests: availableHTTPAttempts
            )
            capabilityLookupHTTPAttempts = lookup.httpRequestCount
            capabilities = lookup.capabilities
        } else {
            capabilityLookupHTTPAttempts = 0
            capabilities = try await catalogService.validatedCapabilitiesForGeneration(
                apiKey: apiKey,
                modelID: model,
                expectedCanonicalModelID: expectedCanonicalModelID,
                maximumHTTPRequests: nil
            ).capabilities
        }
        if countCapabilityLookupHTTPAttempts, capabilityLookupHTTPAttempts > 0 {
            config.usageSink?(.httpAttempts(capabilityLookupHTTPAttempts))
        }
        if countCapabilityLookupHTTPAttempts,
            capabilityLookupHTTPAttempts >= availableHTTPAttempts
        {
            throw OpenRouterHTTPAttemptBudgetExhausted(
                message: "OpenRouter HTTP-attempt budget exhausted before chat completion.",
                backendMetadata: budgetMetadata(
                    requestCount: capabilityLookupHTTPAttempts,
                    capabilities: capabilities
                )
            )
        }
        let remainingHTTPAttempts = countCapabilityLookupHTTPAttempts
            ? max(1, availableHTTPAttempts - capabilityLookupHTTPAttempts)
            : retryPolicy.maxAttempts
        do {
            let parsed = try await performRequest(
                instructions: instructions,
                prompt: prompt,
                capabilities: capabilities,
                maximumHTTPAttempts: remainingHTTPAttempts,
                usageSink: config.usageSink
            )
            let requestCount = capabilityLookupHTTPAttempts + parsed.metadata.requestCount
            let callCount = max(1, context.modelCallCount) + max(0, requestCount - 1)
            var result = parsed.result
            result.generationCallCount = callCount
            result.backendMetadata?.requestCount = requestCount
            result.backendMetadata?.retryCount = parsed.metadata.retryCount
            await GenerationLog.shared.append(
                prompt: prompt,
                outcome: result.logDescription,
                durationMs: elapsedMilliseconds(since: started),
                telemetry: PromptTelemetry(
                    phase: context.mode,
                    package: bundle.schemaPackage,
                    context: context,
                    callCount: callCount,
                    stopReason: result.needsClarification ? "clarification" : "success"
                ))
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as OpenRouterFailure {
            let recordedFailure = capabilityLookupHTTPAttempts > 0
                ? failure.withAttemptCount(failure.diagnostic.attemptCount + capabilityLookupHTTPAttempts)
                : failure
            if failure.category == .unsupportedFeature || failure.category == .invalidRequest {
                await catalogService.invalidate(apiKey: apiKey, modelID: model)
            }
            await GenerationLog.shared.append(
                prompt: prompt,
                outcome: "error: \(failure.category.rawValue)",
                durationMs: elapsedMilliseconds(since: started),
                telemetry: PromptTelemetry(
                    phase: context.mode,
                    package: bundle.schemaPackage,
                    context: context,
                    callCount: max(1, context.modelCallCount)
                        + max(0, recordedFailure.diagnostic.attemptCount - 1),
                    stopReason: failure.category.rawValue
                ))
            throw recordedFailure
        } catch {
            await GenerationLog.shared.append(
                prompt: prompt,
                outcome: "error: networkTransport",
                durationMs: elapsedMilliseconds(since: started),
                telemetry: PromptTelemetry(
                    phase: context.mode,
                    package: bundle.schemaPackage,
                    context: context,
                    callCount: max(1, context.modelCallCount),
                    stopReason: "networkTransport"
                ))
            throw OpenRouterFailure(
                category: .networkTransport,
                message: error.localizedDescription,
                requestedModelID: model,
                attemptCount: max(1, capabilityLookupHTTPAttempts)
            )
        }
    }

    fileprivate func testTinyCompletion(capabilities: OpenRouterModelCapabilities) async throws
        -> OpenRouterGenerationMetadata
    {
        let built = try requestBuilder.buildTinyJSONTest(
            apiKey: apiKey,
            model: model,
            capabilities: capabilities
        )
        let parsed = try await performBuiltRequest(built, requestedModelID: model)
        return parsed.metadata
    }

    private func budgetMetadata(
        requestCount: Int,
        capabilities: OpenRouterModelCapabilities
    ) -> OpenRouterGenerationMetadata {
        OpenRouterGenerationMetadata(
            requestedModelID: model,
            returnedModelID: nil,
            providerName: nil,
            completionID: nil,
            requestID: nil,
            structuredOutputMode: capabilities.supportsStructuredOutputs
                ? .strictJSONSchema
                : .promptOnlyJSON,
            requestCount: requestCount,
            retryCount: 0,
            promptTokens: nil,
            completionTokens: nil,
            reasoningTokens: nil,
            totalTokens: nil,
            costUSD: nil,
            serviceTier: nil,
            finishReason: nil,
            nativeFinishReason: nil
        )
    }

    private func performRequest(
        instructions: String,
        prompt: String,
        capabilities: OpenRouterModelCapabilities,
        maximumHTTPAttempts: Int? = nil,
        usageSink: (@Sendable (SQLGenerationUsageEvent) -> Void)? = nil
    ) async throws -> OpenRouterResponseParser.ParsedResult {
        let built = try requestBuilder.build(
            apiKey: apiKey,
            model: model,
            instructions: instructions,
            prompt: prompt,
            capabilities: capabilities
        )
        return try await performBuiltRequest(
            built,
            requestedModelID: model,
            maximumHTTPAttempts: maximumHTTPAttempts,
            usageSink: usageSink
        )
    }

    private func performBuiltRequest(
        _ built: OpenRouterRequestBuilder.BuiltRequest,
        requestedModelID: String,
        maximumHTTPAttempts: Int? = nil,
        usageSink: (@Sendable (SQLGenerationUsageEvent) -> Void)? = nil
    ) async throws -> OpenRouterResponseParser.ParsedResult {
        let effectiveRetryPolicy = OpenRouterRetryPolicy(
            maxAttempts: maximumHTTPAttempts.map { min(retryPolicy.maxAttempts, max(1, $0)) }
                ?? retryPolicy.maxAttempts
        )
        var attempt = 1
        var noContentRetries = 0
        var failedUsage = OpenRouterUsageAccumulator()
        while true {
            try Task.checkCancellation()
            do {
                usageSink?(.httpAttempts(1))
                let (data, response) = try await transport.send(built.request)
                if let reportedUsage = OpenRouterResponseParser.reportedUsage(from: data) {
                    usageSink?(reportedUsage.generationUsageEvent)
                }
                let retryAfter = retryPolicy.retryAfter(from: response)
                do {
                    var parsed = try parser.parse(
                        data: data,
                        response: response,
                        requestedModelID: requestedModelID,
                        mode: built.mode,
                        requestCount: attempt,
                        retryCount: attempt - 1,
                        expectedCanonicalModelID: expectedCanonicalModelID
                    )
                    parsed.metadata = failedUsage.merging(into: parsed.metadata)
                    parsed.result.backendMetadata = parsed.metadata
                    return parsed
                } catch var failure as OpenRouterFailure {
                    failure.diagnostic.retryAfterSeconds = retryAfter
                    failedUsage.record(failure.diagnostic)
                    if failure.category == .noContent { noContentRetries += 1 }
                    if let delay = effectiveRetryPolicy.retryDelay(
                        for: failure,
                        attempt: attempt,
                        noContentRetries: max(0, noContentRetries - 1)
                    ) {
                        attempt += 1
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    }
                    if let retryAfter, retryAfter > OpenRouterRetryPolicy.retryAfterCap,
                        failure.category == .rateLimited
                    {
                        failure.diagnostic.suggestedWaitSeconds = retryAfter
                    }
                    throw failedUsage.applying(to: failure.withAttemptCount(attempt))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                if error.code == .cancelled, Task.isCancelled {
                    throw CancellationError()
                }
                let failure = Self.map(error, requestedModelID: requestedModelID, attempt: attempt)
                if let delay = effectiveRetryPolicy.retryDelay(
                    for: failure,
                    attempt: attempt,
                    noContentRetries: noContentRetries
                ) {
                    attempt += 1
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw failedUsage.applying(to: failure.withAttemptCount(attempt))
            }
        }
    }

    static let jsonInstructions = """
        Respond with a single JSON object and nothing else, using exactly these keys:
        {"sql": string, "explanation": string, "assumptions": [string], "referencedTables": [string], "confidence": number between 0 and 1, "riskLevel": "low" or "medium" or "high", "needsClarification": boolean, "clarificationQuestion": string or null}
        """

    private static func map(
        _ error: URLError,
        requestedModelID: String,
        attempt: Int
    ) -> OpenRouterFailure {
        switch error.code {
        case .timedOut:
            return OpenRouterFailure(
                category: .timeout,
                message: "The cloud request timed out.",
                requestedModelID: requestedModelID,
                attemptCount: attempt
            )
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
            .cannotConnectToHost, .dnsLookupFailed:
            return OpenRouterFailure(
                category: .networkTransport,
                message: "No internet connection. Check your network and try again.",
                requestedModelID: requestedModelID,
                attemptCount: attempt
            )
        default:
            return OpenRouterFailure(
                category: .networkTransport,
                message: error.localizedDescription,
                requestedModelID: requestedModelID,
                attemptCount: attempt
            )
        }
    }
}

private extension JSONEncoder {
    static var widenOpenRouter: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var widenOpenRouter: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private func elapsedMilliseconds(since date: Date) -> Int {
    Int(Date().timeIntervalSince(date) * 1_000)
}
