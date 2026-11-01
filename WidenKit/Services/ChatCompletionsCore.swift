import Foundation

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

struct OpenRouterReportedUsageEnvelope: Decodable {
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

struct OpenRouterUsageAccumulator {
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

extension OpenRouterFailure {
    /// Maps a URLSession transport error to a chat-completion failure. Shared
    /// by the one-shot generator and the schema-tool agent.
    static func map(
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
