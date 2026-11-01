import Foundation

public enum OpenRouterStructuredOutputMode: String, Codable, CaseIterable, Equatable, Sendable {
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
        OpenRouterProviderPreferences.apply(to: &body)

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
                let failure = OpenRouterFailure.map(error, requestedModelID: requestedModelID, attempt: attempt)
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
}

private func elapsedMilliseconds(since date: Date) -> Int {
    Int(Date().timeIntervalSince(date) * 1_000)
}
