import Foundation

public enum StructuredOutputMode: String, Codable, CaseIterable, Equatable, Sendable {
    case strictJSONSchema
    case promptOnlyJSON
}

public struct CloudModelCapabilities: Codable, Equatable, Sendable {
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

    public static func conservative(fetchedAt: Date = Date()) -> CloudModelCapabilities {
        CloudModelCapabilities(
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

struct ChatCompletionRequestBuilder: Sendable {
    let profile: CloudModelProfile

    init(profile: CloudModelProfile) {
        self.profile = profile
    }

    struct BuiltRequest: Sendable {
        var request: URLRequest
        var mode: StructuredOutputMode
        /// The `response_format` type sent, if any.
        var responseFormatType: String?
        /// The `reasoning_effort` sent, if any.
        var reasoningEffort: String?
    }

    /// `correction`, when set, follows the prompt as a second user message.
    func build(
        apiKey: String,
        instructions: String,
        prompt: String,
        capabilities: CloudModelCapabilities,
        callSite: CloudCallSite = .oneShotSQL,
        promptCacheKey: String? = nil,
        correction: String? = nil
    ) throws -> BuiltRequest {
        let policy = profile.policy(for: callSite)
        let mode: StructuredOutputMode =
            policy.responseFormat == .strictJSONSchemaWhenAdvertised
                && capabilities.supportsStructuredOutputs
            ? .strictJSONSchema
            : .promptOnlyJSON
        var messages = [
            ["role": "system", "content": instructions],
            ["role": "user", "content": prompt],
        ]
        if let correction {
            messages.append(["role": "user", "content": correction])
        }
        var body: [String: Any] = [
            "model": profile.requestedModelID,
            "messages": messages,
            "stream": false,
        ]
        if capabilities.supportsTemperature {
            body["temperature"] = 0
        }
        if capabilities.supportsMaxCompletionTokens {
            body["max_completion_tokens"] = cappedCompletionTokens(policy, capabilities)
        } else if capabilities.supportsMaxTokens {
            body["max_tokens"] = cappedCompletionTokens(policy, capabilities)
        } else if mode == .promptOnlyJSON {
            body["max_tokens"] = policy.maxCompletionTokens
        }
        var responseFormatType: String?
        if mode == .strictJSONSchema {
            body["response_format"] = Self.responseFormat()
            responseFormatType = "json_schema"
        } else if policy.responseFormat == .jsonObject, capabilities.supportsResponseFormat {
            // json_object is checked for syntax only, so the schema stays
            // prompt-enforced and the result is still promptOnlyJSON.
            body["response_format"] = ["type": "json_object"]
            responseFormatType = "json_object"
        }
        if let reasoningEffort = policy.reasoningEffort {
            body["reasoning_effort"] = reasoningEffort.rawValue
        }
        if profile.usesPromptCacheKey, let promptCacheKey {
            body["prompt_cache_key"] = promptCacheKey
        }
        if profile.usesOpenRouterRouting {
            OpenRouterProviderPreferences.apply(to: &body)
        }

        var request = try profile.authorizedRequest(profile.chatCompletionsURL, apiKey: apiKey)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return BuiltRequest(
            request: request,
            mode: mode,
            responseFormatType: responseFormatType,
            reasoningEffort: policy.reasoningEffort?.rawValue
        )
    }

    func buildTinyJSONTest(
        apiKey: String,
        capabilities: CloudModelCapabilities
    ) throws -> BuiltRequest {
        try build(
            apiKey: apiKey,
            instructions: """
                Respond with a single JSON object and nothing else, using exactly these keys:
                {"sql": string, "explanation": string, "assumptions": [string], "referencedTables": [string], "confidence": number between 0 and 1, "riskLevel": "low" or "medium" or "high", "needsClarification": boolean, "clarificationQuestion": string or null}
                """,
            prompt: """
                Return a minimal connectivity response for SELECT 1.
                """,
            capabilities: capabilities,
            callSite: .connectivityProbe
        )
    }

    private func cappedCompletionTokens(
        _ policy: CloudCallSitePolicy,
        _ capabilities: CloudModelCapabilities
    ) -> Int {
        min(
            policy.maxCompletionTokens,
            max(16, capabilities.maximumCompletionTokens ?? policy.maxCompletionTokens)
        )
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

struct CloudSQLResponseParser: Sendable {
    struct ParsedResult: Sendable {
        var result: SQLGenerationResult
        var metadata: CloudGenerationMetadata
    }

    let profile: CloudModelProfile

    init(profile: CloudModelProfile) {
        self.profile = profile
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
            let error: ChatCompletionErrorEnvelope.APIError?

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
        let usage: ChatCompletionUsage?
        let error: ChatCompletionErrorEnvelope.APIError?
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
            usage = try container.decodeIfPresent(ChatCompletionUsage.self, forKey: .usage)
            error = try container.decodeIfPresent(ChatCompletionErrorEnvelope.APIError.self, forKey: .error)
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
        mode: StructuredOutputMode,
        requestCount: Int,
        retryCount: Int
    ) throws -> ParsedResult {
        let reportedUsage = Self.reportedUsage(from: data, profile: profile)
        if !(200..<300).contains(response.statusCode) {
            throw Self.failure(
                from: data,
                response: response,
                requestedModelID: requestedModelID,
                attemptCount: requestCount,
                profile: profile
            ).withReportedUsage(reportedUsage)
        }
        let requestID = Self.requestID(from: response, profile: profile)
        let completion: ChatResponse
        do {
            completion = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw CloudRequestFailure(
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
                attemptCount: requestCount,
                profile: profile
            ).withReportedUsage(reportedUsage)
        }
        guard let choice = completion.choices.first else {
            throw CloudRequestFailure(
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
                attemptCount: requestCount,
                profile: profile
            ).withReportedUsage(reportedUsage)
        }
        if choice.finishReason == "error" {
            throw CloudRequestFailure(
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
            throw CloudRequestFailure(
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
            throw CloudRequestFailure(
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
            throw CloudRequestFailure(
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
            throw CloudRequestFailure(
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
            try CloudModelIdentityValidator.validate(
                profile: profile,
                returnedModelID: completion.model,
                routerMetadata: completion.openrouterMetadata,
                requestedModelID: requestedModelID,
                httpStatus: response.statusCode,
                completionID: completion.id,
                requestID: requestID,
                providerName: completion.provider ?? completion.openrouterMetadata?.selectedProvider,
                attemptCount: requestCount
            )
        } catch let failure as CloudRequestFailure {
            throw failure.withReportedUsage(reportedUsage)
        }
        let objectData: Data
        switch mode {
        case .strictJSONSchema:
            objectData = Data(content.utf8)
        case .promptOnlyJSON:
            guard let data = Self.promptOnlyJSONObjectData(from: content) else {
                throw CloudRequestFailure(
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
            throw CloudRequestFailure(
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
            throw CloudRequestFailure(
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
            throw CloudRequestFailure(
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

        let usage = completion.usage?.priced(by: profile)
        let metadata = CloudGenerationMetadata(
            providerID: profile.provider.rawValue,
            requestedModelID: requestedModelID,
            returnedModelID: completion.model,
            providerName: completion.provider ?? completion.openrouterMetadata?.selectedProvider,
            completionID: completion.id,
            requestID: requestID,
            structuredOutputMode: mode,
            requestCount: requestCount,
            retryCount: retryCount,
            promptTokens: usage?.promptTokens,
            cachedPromptTokens: usage?.cachedTokens,
            completionTokens: usage?.completionTokens,
            reasoningTokens: usage?.completionTokensDetails?.reasoningTokens,
            totalTokens: usage?.totalTokens,
            costUSD: usage?.costUSD,
            costSource: usage?.costSource,
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

    /// The first of the profile's request-ID headers the response carries.
    /// Header lookup is case-insensitive.
    static func requestID(from response: HTTPURLResponse, profile: CloudModelProfile) -> String? {
        for name in profile.requestIDHeaderNames {
            if let value = response.value(forHTTPHeaderField: name) {
                return value
            }
        }
        return nil
    }

    /// The response's usage, priced by the profile when the provider reports
    /// no cost.
    static func reportedUsage(from data: Data, profile: CloudModelProfile) -> ChatCompletionUsage? {
        guard let envelope = try? JSONDecoder().decode(
            ChatCompletionUsageEnvelope.self,
            from: data
        ) else { return nil }
        return envelope.usage?.priced(by: profile)
    }

    static func failure(
        from data: Data,
        response: HTTPURLResponse,
        requestedModelID: String?,
        attemptCount: Int,
        retryAfterSeconds: Double? = nil,
        profile: CloudModelProfile
    ) -> CloudRequestFailure {
        let requestID = requestID(from: response, profile: profile)
        if let envelope = try? JSONDecoder().decode(ChatCompletionErrorEnvelope.self, from: data),
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
                attemptCount: attemptCount,
                profile: profile
            )
            failure.diagnostic.retryAfterSeconds = retryAfterSeconds
            return failure
        }
        let message = HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        return CloudRequestFailure(
            category: CloudRequestFailure.category(
                errorType: nil,
                providerCode: nil,
                httpStatus: response.statusCode,
                message: message,
                profile: profile
            ),
            message: "\(profile.provider.displayName) returned HTTP \(response.statusCode).",
            httpStatus: response.statusCode,
            requestID: requestID,
            requestedModelID: requestedModelID,
            retryAfterSeconds: retryAfterSeconds,
            attemptCount: attemptCount
        )
    }

    /// OpenRouter puts the error type and provider code in `metadata`;
    /// Particle sends them as `error.type` and a string `error.code`. Either
    /// way they are kept as `providerErrorType` and `providerCode`. An
    /// OpenRouter profile reads only `metadata`, as it always has, so a
    /// passed-through upstream `type` or `code` changes neither its category
    /// nor its recorded diagnostics.
    static func failure(
        apiError: ChatCompletionErrorEnvelope.APIError,
        httpStatus: Int?,
        completionID: String?,
        requestID: String?,
        requestedModelID: String?,
        returnedModelID: String?,
        providerName: String?,
        attemptCount: Int,
        profile: CloudModelProfile
    ) -> CloudRequestFailure {
        let fallbackMessage = "\(profile.provider.displayName) returned an error."
        let message = apiError.message ?? fallbackMessage
        let effectiveHTTPStatus = apiError.httpStatusCode ?? httpStatus
        let readsTopLevelFields = !profile.usesOpenRouterRouting
        let providerErrorType = apiError.metadata?.errorType
            ?? (readsTopLevelFields ? apiError.type : nil)
        let providerCode = apiError.metadata?.providerCode
            ?? (readsTopLevelFields ? apiError.typedCode : nil)
        var displayMessage = safeMessage(message, fallback: fallbackMessage)
        if profile.usesOpenRouterRouting, isProviderRoutingPolicyMessage(message) {
            displayMessage =
                "No OpenRouter endpoint met Widen's private-routing requirements for this model. Widen requires zero data retention, no provider data collection, and full request-parameter support, and fails closed rather than relaxing them. \(displayMessage)"
        }
        return CloudRequestFailure(
            category: CloudRequestFailure.category(
                errorType: providerErrorType,
                providerCode: providerCode,
                httpStatus: effectiveHTTPStatus,
                message: message,
                profile: profile
            ),
            message: displayMessage,
            httpStatus: effectiveHTTPStatus,
            providerErrorType: providerErrorType,
            providerCode: providerCode,
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

    private static func safeMessage(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return String(trimmed.prefix(240))
    }
}

struct OpenRouterConnectivityCheck: Sendable {
    struct Result: Equatable, Sendable {
        var keyAccepted: Bool
        var selectedModelAvailable: Bool
        var capabilities: CloudModelCapabilities
        var returnedModelID: String?
        var providerName: String?
        var latencyMs: Int
        var retryCount: Int
        var error: CloudRequestFailure?
    }

    let apiKey: String
    let profile: CloudModelProfile
    let catalogService: OpenRouterModelCatalogService?
    let transport: any HTTPTransport

    /// Only an OpenRouter profile has a catalog to check; any other profile
    /// fails without sending a request.
    init(
        apiKey: String,
        profile: CloudModelProfile,
        catalogService: OpenRouterModelCatalogService? = nil,
        transport: (any HTTPTransport)? = nil
    ) {
        self.apiKey = apiKey
        self.profile = profile
        self.catalogService = catalogService ?? .evalShared(for: profile)
        self.transport = transport ?? URLSessionTransport(timeoutsOf: profile)
    }

    func run() async -> Result {
        let started = Date()
        let model = profile.requestedModelID
        guard let catalogService else {
            return Result(
                keyAccepted: false,
                selectedModelAvailable: false,
                capabilities: .conservative(),
                returnedModelID: nil,
                providerName: nil,
                latencyMs: 0,
                retryCount: 0,
                error: CloudRequestFailure(
                    category: .unsupportedFeature,
                    message: "The OpenRouter connectivity check only supports OpenRouter profiles.",
                    requestedModelID: model,
                    attemptCount: 0
                )
            )
        }
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
                expectedCanonicalModelID: profile.expectedReturnedModelID,
                requestedModelID: model
            )
            let generator = CloudSQLGenerator(
                apiKey: apiKey,
                profile: profile,
                transport: transport,
                capabilityResolver: CloudCapabilityResolver(
                    profile: profile,
                    catalogService: catalogService
                )
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
        } catch let failure as CloudRequestFailure {
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
            let failure = CloudRequestFailure(
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

/// Generates SQL with a hosted model through an OpenAI-compatible
/// chat-completions API described by a cloud model profile. It keeps the same
/// SQL prompts as the local model, but chooses the transport mode from the
/// profile's model capabilities.
public final class CloudSQLGenerator: SQLGenerator, Sendable {
    static let schemaCharacterBudget = 60_000

    private let apiKey: String
    let profile: CloudModelProfile
    private let transport: any HTTPTransport
    private let capabilityResolver: CloudCapabilityResolver
    private let requestBuilder: ChatCompletionRequestBuilder
    private let parser: CloudSQLResponseParser
    private let retryPolicy: ChatCompletionRetryPolicy
    private let countCapabilityLookupHTTPAttempts: Bool
    private let preResolvedCapabilities: CloudModelCapabilities?

    var model: String { profile.requestedModelID }
    var expectedCanonicalModelID: String? { profile.expectedReturnedModelID }

    /// Requests go only to `profile`'s host. Without a transport, one is
    /// built with the profile's timeouts.
    public convenience init(
        apiKey: String,
        profile: CloudModelProfile = CloudModelCatalog.productionProfile,
        transport: (any HTTPTransport)? = nil,
        maximumHTTPAttempts: Int = 3,
        countCapabilityLookupHTTPAttempts: Bool = false
    ) {
        self.init(
            apiKey: apiKey,
            profile: profile,
            transport: transport ?? URLSessionTransport(timeoutsOf: profile),
            capabilityResolver: CloudCapabilityResolver(profile: profile),
            retryPolicy: ChatCompletionRetryPolicy(maxAttempts: maximumHTTPAttempts),
            countCapabilityLookupHTTPAttempts: countCapabilityLookupHTTPAttempts
        )
    }

    init(
        apiKey: String,
        profile: CloudModelProfile,
        transport: any HTTPTransport,
        capabilityResolver: CloudCapabilityResolver,
        retryPolicy: ChatCompletionRetryPolicy = ChatCompletionRetryPolicy(),
        countCapabilityLookupHTTPAttempts: Bool = false,
        preResolvedCapabilities: CloudModelCapabilities? = nil
    ) {
        self.apiKey = apiKey
        self.profile = profile
        self.transport = transport
        self.capabilityResolver = capabilityResolver
        self.requestBuilder = ChatCompletionRequestBuilder(profile: profile)
        self.parser = CloudSQLResponseParser(profile: profile)
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
        let promptCacheKey = profile.makePromptCacheKey()
        let availableHTTPAttempts = countCapabilityLookupHTTPAttempts
            ? HTTPAttemptBudget.remaining(
                maximumHTTPAttempts: retryPolicy.maxAttempts,
                contextModelCallCount: context.modelCallCount
            )
            : retryPolicy.maxAttempts
        guard availableHTTPAttempts > 0 else {
            throw HTTPAttemptBudgetExhausted(
                message: "OpenRouter HTTP-attempt budget exhausted before generation."
            )
        }
        let capabilityLookupHTTPAttempts: Int
        let capabilities: CloudModelCapabilities
        if let preResolvedCapabilities {
            // Pre-resolved capabilities were already validated by the caller:
            // the schema-tool agent's legacy fallback passes capabilities it
            // resolved through validatedCapabilitiesForGeneration.
            capabilityLookupHTTPAttempts = 0
            capabilities = preResolvedCapabilities
        } else if countCapabilityLookupHTTPAttempts {
            let lookup = try await capabilityResolver.validatedCapabilitiesForGeneration(
                apiKey: apiKey,
                maximumHTTPRequests: availableHTTPAttempts
            )
            capabilityLookupHTTPAttempts = lookup.httpRequestCount
            capabilities = lookup.capabilities
        } else {
            capabilityLookupHTTPAttempts = 0
            capabilities = try await capabilityResolver.validatedCapabilitiesForGeneration(
                apiKey: apiKey,
                maximumHTTPRequests: nil
            ).capabilities
        }
        if countCapabilityLookupHTTPAttempts, capabilityLookupHTTPAttempts > 0 {
            config.usageSink?(.httpAttempts(capabilityLookupHTTPAttempts))
        }
        if countCapabilityLookupHTTPAttempts,
            capabilityLookupHTTPAttempts >= availableHTTPAttempts
        {
            throw HTTPAttemptBudgetExhausted(
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
                promptCacheKey: promptCacheKey,
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
        } catch let failure as CloudRequestFailure {
            let recordedFailure = capabilityLookupHTTPAttempts > 0
                ? failure.withAttemptCount(failure.diagnostic.attemptCount + capabilityLookupHTTPAttempts)
                : failure
            if failure.category == .unsupportedFeature || failure.category == .invalidRequest {
                await capabilityResolver.invalidate(apiKey: apiKey)
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
            throw CloudRequestFailure(
                category: .networkTransport,
                message: error.localizedDescription,
                requestedModelID: model,
                attemptCount: max(1, capabilityLookupHTTPAttempts)
            )
        }
    }

    fileprivate func testTinyCompletion(capabilities: CloudModelCapabilities) async throws
        -> CloudGenerationMetadata
    {
        let built = try requestBuilder.buildTinyJSONTest(
            apiKey: apiKey,
            capabilities: capabilities
        )
        let parsed = try await performBuiltRequest(built, requestedModelID: model)
        return parsed.metadata
    }

    private func budgetMetadata(
        requestCount: Int,
        capabilities: CloudModelCapabilities
    ) -> CloudGenerationMetadata {
        CloudGenerationMetadata(
            providerID: profile.provider.rawValue,
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
        capabilities: CloudModelCapabilities,
        promptCacheKey: String?,
        maximumHTTPAttempts: Int? = nil,
        usageSink: (@Sendable (SQLGenerationUsageEvent) -> Void)? = nil
    ) async throws -> CloudSQLResponseParser.ParsedResult {
        let built = try requestBuilder.build(
            apiKey: apiKey,
            instructions: instructions,
            prompt: prompt,
            capabilities: capabilities,
            promptCacheKey: promptCacheKey
        )
        let corrected = try requestBuilder.build(
            apiKey: apiKey,
            instructions: instructions,
            prompt: prompt,
            capabilities: capabilities,
            promptCacheKey: promptCacheKey,
            correction: Self.invalidOutputCorrection
        )
        return try await performBuiltRequest(
            built,
            correctedForInvalidOutput: corrected,
            requestedModelID: model,
            maximumHTTPAttempts: maximumHTTPAttempts,
            usageSink: usageSink
        )
    }

    /// `correctedForInvalidOutput` replaces the request for the one resend
    /// after `invalid_model_output`; without it the same request is resent.
    private func performBuiltRequest(
        _ built: ChatCompletionRequestBuilder.BuiltRequest,
        correctedForInvalidOutput: ChatCompletionRequestBuilder.BuiltRequest? = nil,
        requestedModelID: String,
        maximumHTTPAttempts: Int? = nil,
        usageSink: (@Sendable (SQLGenerationUsageEvent) -> Void)? = nil
    ) async throws -> CloudSQLResponseParser.ParsedResult {
        let effectiveRetryPolicy = ChatCompletionRetryPolicy(
            maxAttempts: maximumHTTPAttempts.map { min(retryPolicy.maxAttempts, max(1, $0)) }
                ?? retryPolicy.maxAttempts
        )
        var built = built
        var attempt = 1
        var noContentRetries = 0
        var invalidOutputRetries = 0
        var failedUsage = ChatCompletionUsageAccumulator()
        while true {
            try Task.checkCancellation()
            do {
                usageSink?(.httpAttempts(1))
                let (data, response) = try await transport.send(built.request)
                if let reportedUsage = CloudSQLResponseParser.reportedUsage(
                    from: data,
                    profile: profile
                ) {
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
                        retryCount: attempt - 1
                    )
                    parsed.metadata = failedUsage.merging(into: parsed.metadata)
                    parsed.metadata.responseFormatType = built.responseFormatType
                    parsed.metadata.reasoningEffort = built.reasoningEffort
                    parsed.result.backendMetadata = parsed.metadata
                    return parsed
                } catch var failure as CloudRequestFailure {
                    failure.diagnostic.retryAfterSeconds = retryAfter
                    failedUsage.record(failure.diagnostic)
                    if failure.category == .noContent { noContentRetries += 1 }
                    if let delay = effectiveRetryPolicy.retryDelay(
                        for: failure,
                        attempt: attempt,
                        noContentRetries: max(0, noContentRetries - 1),
                        invalidOutputRetries: invalidOutputRetries
                    ) {
                        if failure.isInvalidModelOutput {
                            invalidOutputRetries += 1
                            built = correctedForInvalidOutput ?? built
                        }
                        attempt += 1
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    }
                    if let retryAfter, retryAfter > ChatCompletionRetryPolicy.retryAfterCap,
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
                let failure = CloudRequestFailure.map(error, requestedModelID: requestedModelID, attempt: attempt)
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

    /// Sent after `invalid_model_output`, when the provider rejected the
    /// model's reply as invalid JSON.
    static let invalidOutputCorrection = """
        Your previous reply was not a valid JSON object. Reply with exactly one valid JSON object and nothing else, using exactly the keys sql, explanation, assumptions, referencedTables, confidence, riskLevel, needsClarification and clarificationQuestion.
        """

    static let jsonInstructions = """
        Respond with a single JSON object and nothing else, using exactly these keys:
        {"sql": string, "explanation": string, "assumptions": [string], "referencedTables": [string], "confidence": number between 0 and 1, "riskLevel": "low" or "medium" or "high", "needsClarification": boolean, "clarificationQuestion": string or null}
        """
}

private func elapsedMilliseconds(since date: Date) -> Int {
    Int(Date().timeIntervalSince(date) * 1_000)
}
