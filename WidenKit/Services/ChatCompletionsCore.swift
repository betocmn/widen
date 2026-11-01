import Foundation

/// Where a request's `costUSD` came from. Metadata and diagnostics store the
/// raw value as a plain string, so a source added later never stops an older
/// build from reading saved sessions.
enum CloudCostSource: String, CaseIterable, Sendable {
    /// The provider reported `usage.cost`.
    case reported
    /// Estimated from the profile's peak list prices, so an upper bound.
    case estimatedPeakList

    /// The source of a cost summed from two parts. A total with any
    /// estimated part is itself an estimate.
    static func combined(_ first: String?, _ second: String?) -> String? {
        guard let first else { return second }
        guard let second, second != first else { return first }
        return estimatedPeakList.rawValue
    }
}

struct ChatCompletionUsage: Decodable, Equatable, Sendable {
    struct PromptDetails: Decodable, Equatable, Sendable {
        let cachedTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
        }
    }

    struct CompletionDetails: Decodable, Equatable, Sendable {
        let reasoningTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case reasoningTokens = "reasoning_tokens"
        }
    }

    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    let promptTokensDetails: PromptDetails?
    let completionTokensDetails: CompletionDetails?
    let cost: Double?
    /// Set by `priced(by:)` when the provider reports no `usage.cost`.
    private(set) var estimatedCostUSD: Double? = nil

    private enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case promptTokensDetails = "prompt_tokens_details"
        case completionTokensDetails = "completion_tokens_details"
        case cost
    }

    var cachedTokens: Int? {
        promptTokensDetails?.cachedTokens
    }

    /// The reported `usage.cost`, or else the estimate from `priced(by:)`.
    var costUSD: Double? {
        cost ?? estimatedCostUSD
    }

    var costSource: String? {
        if cost != nil { return CloudCostSource.reported.rawValue }
        return estimatedCostUSD == nil ? nil : CloudCostSource.estimatedPeakList.rawValue
    }

    /// Adds a cost estimate from the profile's prices when the provider
    /// reports token counts but no `usage.cost`. A reported cost always wins.
    func priced(by profile: CloudModelProfile) -> ChatCompletionUsage {
        guard cost == nil,
            let pricing = profile.pricing,
            promptTokens != nil || completionTokens != nil
        else { return self }
        var copy = self
        copy.estimatedCostUSD = pricing.estimatedCostUSD(
            prompt: promptTokens ?? 0,
            cached: cachedTokens ?? 0,
            completion: completionTokens ?? 0
        )
        return copy
    }

    var generationUsageEvent: SQLGenerationUsageEvent {
        SQLGenerationUsageEvent(
            httpAttemptCount: 0,
            promptTokens: promptTokens,
            cachedPromptTokens: cachedTokens,
            completionTokens: completionTokens,
            reasoningTokens: completionTokensDetails?.reasoningTokens,
            totalTokens: totalTokens,
            costUSD: costUSD,
            costSource: costSource
        )
    }
}

struct ChatCompletionUsageEnvelope: Decodable {
    let usage: ChatCompletionUsage?
}

public struct CloudGenerationMetadata: Codable, Equatable, Sendable {
    /// The profile's `CloudModelProviderID` raw value.
    public var providerID: String?
    public var requestedModelID: String
    public var returnedModelID: String?
    public var providerName: String?
    public var completionID: String?
    public var requestID: String?
    public var structuredOutputMode: StructuredOutputMode
    /// The `response_format` type sent, such as `json_object`. A json_object
    /// request is still `promptOnlyJSON`, because only its syntax is checked.
    public var responseFormatType: String?
    /// The `reasoning_effort` sent; nil when the field was omitted.
    public var reasoningEffort: String?
    public var requestCount: Int
    public var retryCount: Int
    public var promptTokens: Int?
    /// Prompt tokens served from the provider's prompt cache.
    public var cachedPromptTokens: Int?
    public var completionTokens: Int?
    public var reasoningTokens: Int?
    public var totalTokens: Int?
    public var costUSD: Double?
    /// A `CloudCostSource` raw value: `reported`, or `estimatedPeakList` for
    /// a local upper-bound estimate.
    public var costSource: String?
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
    public var agentDiagnostics: SchemaToolAgentDiagnostics?
}

public struct CloudRequestFailureDiagnostic: Codable, Equatable, Sendable {
    public var category: CloudRequestFailure.Category
    public var httpStatus: Int?
    public var providerErrorType: String?
    public var providerCode: String?
    public var completionID: String?
    public var requestID: String?
    public var requestedModelID: String?
    public var returnedModelID: String?
    public var providerName: String?
    public var retryAfterSeconds: Double?
    public var suggestedWaitSeconds: Double?
    public var promptTokens: Int?
    public var cachedPromptTokens: Int?
    public var completionTokens: Int?
    public var reasoningTokens: Int?
    public var totalTokens: Int?
    public var costUSD: Double?
    /// A `CloudCostSource` raw value.
    public var costSource: String?
    public var attemptCount: Int

    /// `providerErrorType` keeps its original `openRouterErrorType` key so
    /// saved pipeline failures and eval results still decode.
    private enum CodingKeys: String, CodingKey {
        case category
        case httpStatus
        case providerErrorType = "openRouterErrorType"
        case providerCode
        case completionID
        case requestID
        case requestedModelID
        case returnedModelID
        case providerName
        case retryAfterSeconds
        case suggestedWaitSeconds
        case promptTokens
        case cachedPromptTokens
        case completionTokens
        case reasoningTokens
        case totalTokens
        case costUSD
        case costSource
        case attemptCount
    }
}

public struct CloudRequestFailure: Error, LocalizedError, Equatable, Sendable {
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
    public var diagnostic: CloudRequestFailureDiagnostic

    public init(
        category: Category,
        message: String,
        httpStatus: Int? = nil,
        providerErrorType: String? = nil,
        providerCode: String? = nil,
        completionID: String? = nil,
        requestID: String? = nil,
        requestedModelID: String? = nil,
        returnedModelID: String? = nil,
        providerName: String? = nil,
        retryAfterSeconds: Double? = nil,
        suggestedWaitSeconds: Double? = nil,
        promptTokens: Int? = nil,
        cachedPromptTokens: Int? = nil,
        completionTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        totalTokens: Int? = nil,
        costUSD: Double? = nil,
        costSource: String? = nil,
        attemptCount: Int = 1
    ) {
        self.category = category
        self.message = message
        self.diagnostic = CloudRequestFailureDiagnostic(
            category: category,
            httpStatus: httpStatus,
            providerErrorType: providerErrorType,
            providerCode: providerCode,
            completionID: completionID,
            requestID: requestID,
            requestedModelID: requestedModelID,
            returnedModelID: returnedModelID,
            providerName: providerName,
            retryAfterSeconds: retryAfterSeconds,
            suggestedWaitSeconds: suggestedWaitSeconds,
            promptTokens: promptTokens,
            cachedPromptTokens: cachedPromptTokens,
            completionTokens: completionTokens,
            reasoningTokens: reasoningTokens,
            totalTokens: totalTokens,
            costUSD: costUSD,
            costSource: costSource,
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

    func withAttemptCount(_ count: Int) -> CloudRequestFailure {
        var copy = self
        copy.diagnostic.attemptCount = count
        return copy
    }

    func withReportedUsage(_ usage: ChatCompletionUsage?) -> CloudRequestFailure {
        guard let usage else { return self }
        var copy = self
        copy.diagnostic.promptTokens = usage.promptTokens
        copy.diagnostic.cachedPromptTokens = usage.cachedTokens
        copy.diagnostic.completionTokens = usage.completionTokens
        copy.diagnostic.reasoningTokens = usage.completionTokensDetails?.reasoningTokens
        copy.diagnostic.totalTokens = usage.totalTokens
        copy.diagnostic.costUSD = usage.costUSD
        copy.diagnostic.costSource = usage.costSource
        return copy
    }

    /// True for Particle's `invalid_model_output`: the model's reply failed
    /// the provider's JSON check. It is the only parsing failure resent.
    var isInvalidModelOutput: Bool {
        category == .malformedStructuredResponse
            && diagnostic.providerCode?.lowercased() == "invalid_model_output"
    }

    /// Classifies a provider error. In order: the profile's typed error
    /// codes, the known provider codes, the profile's error types, the known
    /// error types, OpenRouter's message wording (OpenRouter profiles only),
    /// and finally the HTTP status.
    static func category(
        errorType: String?,
        providerCode: String? = nil,
        httpStatus: Int?,
        message: String?,
        profile: CloudModelProfile
    ) -> Category {
        let code = providerCode?.lowercased()
        if let code, let category = profile.errorCodeCategories[code] {
            return category
        }
        switch code {
        case "provider_limit", "provider_limit_exceeded", "provider_quota_exceeded":
            return .providerLimit
        case "payment_required", "insufficient_credits", "credits", "credits_exhausted":
            return .paymentRequired
        default:
            break
        }

        let type = errorType?.lowercased()
        if let type, let category = profile.errorTypeCategories[type] {
            return category
        }
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

        if profile.usesOpenRouterRouting {
            if let message, CloudSQLResponseParser.isProviderOverloadMessage(message) {
                return .providerOverloaded
            }

            // OpenRouter reports an exhausted key/credit limit as a plain 403
            // message without a typed code; classify it as provider budget so
            // eval runs count it as budget-unavailable, not permission denied.
            // Gate by status: 401 stays authentication and 5xx stays retryable
            // even when a provider message mentions a limit. Effective 2xx
            // covers provider errors delivered inside HTTP-200 envelopes.
            if let message, CloudSQLResponseParser.isKeyOrCreditLimitMessage(message),
                httpStatus.map({ [402, 403, 429].contains($0) || (200...299).contains($0) }) ?? true
            {
                return .providerLimit
            }
        }

        switch httpStatus {
        case 400:
            if let message, CloudSQLResponseParser.isContextWindowMessage(message) {
                return .contextWindow
            }
            if let message, CloudSQLResponseParser.isUnsupportedFeatureMessage(message) {
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
            if let message, CloudSQLResponseParser.isContextWindowMessage(message) {
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

extension CloudRequestFailure.Category {
    var isProviderBudgetUnavailable: Bool {
        self == .paymentRequired || self == .providerLimit
    }
}

struct ChatCompletionUsageAccumulator {
    var promptTokens: Int?
    var cachedPromptTokens: Int?
    var completionTokens: Int?
    var reasoningTokens: Int?
    var totalTokens: Int?
    var costUSD: Double?
    var costSource: String?

    mutating func record(_ diagnostic: CloudRequestFailureDiagnostic) {
        Self.add(diagnostic.promptTokens, to: &promptTokens)
        Self.add(diagnostic.cachedPromptTokens, to: &cachedPromptTokens)
        Self.add(diagnostic.completionTokens, to: &completionTokens)
        Self.add(diagnostic.reasoningTokens, to: &reasoningTokens)
        Self.add(diagnostic.totalTokens, to: &totalTokens)
        Self.add(diagnostic.costUSD, to: &costUSD)
        costSource = CloudCostSource.combined(costSource, diagnostic.costSource)
    }

    func merging(into metadata: CloudGenerationMetadata) -> CloudGenerationMetadata {
        var copy = metadata
        copy.promptTokens = Self.sum(promptTokens, copy.promptTokens)
        copy.cachedPromptTokens = Self.sum(cachedPromptTokens, copy.cachedPromptTokens)
        copy.completionTokens = Self.sum(completionTokens, copy.completionTokens)
        copy.reasoningTokens = Self.sum(reasoningTokens, copy.reasoningTokens)
        copy.totalTokens = Self.sum(totalTokens, copy.totalTokens)
        copy.costUSD = Self.sum(costUSD, copy.costUSD)
        copy.costSource = CloudCostSource.combined(costSource, copy.costSource)
        return copy
    }

    func applying(to failure: CloudRequestFailure) -> CloudRequestFailure {
        var copy = failure
        copy.diagnostic.promptTokens = promptTokens
        copy.diagnostic.cachedPromptTokens = cachedPromptTokens
        copy.diagnostic.completionTokens = completionTokens
        copy.diagnostic.reasoningTokens = reasoningTokens
        copy.diagnostic.totalTokens = totalTokens
        copy.diagnostic.costUSD = costUSD
        copy.diagnostic.costSource = costSource
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

struct ChatCompletionErrorEnvelope: Decodable {
    struct APIError: Decodable {
        struct Metadata: Decodable {
            let errorType: String?
            let providerCode: String?

            private enum CodingKeys: String, CodingKey {
                case errorType = "error_type"
                case providerCode = "provider_code"
            }
        }

        /// OpenRouter sends the HTTP status here; Particle sends a typed
        /// string code such as `insufficient_credits`.
        let code: OpenRouterJSONValue?
        /// Particle's error type, such as `authentication_error`.
        let type: String?
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

        /// A non-numeric string `code`.
        var typedCode: String? {
            guard case .string(let value) = code, Int(value) == nil else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
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

struct ChatCompletionRetryPolicy: Sendable {
    static let defaultMaxAttempts = 3
    static let retryAfterCap: TimeInterval = 15

    var maxAttempts: Int

    init(maxAttempts: Int = Self.defaultMaxAttempts) {
        self.maxAttempts = max(1, maxAttempts)
    }

    /// The delay before resending, or nil to stop. `invalidOutputRetries`
    /// counts earlier resends after `invalid_model_output`; that failure is
    /// resent once, and every resend still uses an HTTP attempt.
    func retryDelay(
        for failure: CloudRequestFailure,
        attempt: Int,
        noContentRetries: Int,
        invalidOutputRetries: Int = 0
    ) -> TimeInterval? {
        guard attempt < maxAttempts else { return nil }
        if failure.category == .noContent, noContentRetries >= 1 { return nil }
        let isInvalidModelOutput = failure.isInvalidModelOutput
        if isInvalidModelOutput {
            guard invalidOutputRetries < 1 else { return nil }
        } else {
            guard isRetryable(failure.category) else { return nil }
        }
        if let retryAfter = failure.diagnostic.retryAfterSeconds {
            guard retryAfter <= Self.retryAfterCap else { return nil }
            return max(0, retryAfter)
        }
        let base = attempt == 1 || isInvalidModelOutput ? 0.5 : 1.0
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

    private func isRetryable(_ category: CloudRequestFailure.Category) -> Bool {
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

extension CloudRequestFailure {
    /// Maps a URLSession transport error to a chat-completion failure. Shared
    /// by the one-shot generator and the schema-tool agent.
    static func map(
        _ error: URLError,
        requestedModelID: String,
        attempt: Int
    ) -> CloudRequestFailure {
        switch error.code {
        case .timedOut:
            return CloudRequestFailure(
                category: .timeout,
                message: "The cloud request timed out.",
                requestedModelID: requestedModelID,
                attemptCount: attempt
            )
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
            .cannotConnectToHost, .dnsLookupFailed:
            return CloudRequestFailure(
                category: .networkTransport,
                message: "No internet connection. Check your network and try again.",
                requestedModelID: requestedModelID,
                attemptCount: attempt
            )
        default:
            return CloudRequestFailure(
                category: .networkTransport,
                message: error.localizedDescription,
                requestedModelID: requestedModelID,
                attemptCount: attempt
            )
        }
    }
}

/// Resolves a profile's model capabilities before a completion. A profile
/// with static capabilities answers locally and sends nothing; only an
/// OpenRouter eval profile consults the authenticated OpenRouter catalog.
struct CloudCapabilityResolver: Sendable {
    let profile: CloudModelProfile
    private let catalogService: OpenRouterModelCatalogService?

    /// `catalogService` is a test seam; it is ignored for static profiles.
    init(profile: CloudModelProfile, catalogService: OpenRouterModelCatalogService? = nil) {
        self.profile = profile
        switch profile.capabilityResolution {
        case .staticCapabilities:
            self.catalogService = nil
        case .openRouterCatalog:
            self.catalogService = catalogService ?? .evalShared(for: profile)
        }
    }

    /// Lookup HTTP requests are reported in `httpRequestCount`; static
    /// capabilities always report zero.
    func validatedCapabilitiesForGeneration(
        apiKey: String,
        maximumHTTPRequests: Int?
    ) async throws -> OpenRouterModelCapabilitiesLookup {
        switch profile.capabilityResolution {
        case .staticCapabilities(let capabilities):
            return OpenRouterModelCapabilitiesLookup(capabilities: capabilities, httpRequestCount: 0)
        case .openRouterCatalog:
            guard let catalogService else {
                return OpenRouterModelCapabilitiesLookup(
                    capabilities: .conservative(),
                    httpRequestCount: 0
                )
            }
            return try await catalogService.validatedCapabilitiesForGeneration(
                apiKey: apiKey,
                modelID: profile.requestedModelID,
                expectedCanonicalModelID: profile.expectedReturnedModelID,
                maximumHTTPRequests: maximumHTTPRequests
            )
        }
    }

    /// Drops cached catalog capabilities after the provider rejected a
    /// request parameter. A no-op for static capabilities.
    func invalidate(apiKey: String) async {
        await catalogService?.invalidate(apiKey: apiKey, modelID: profile.requestedModelID)
    }
}
