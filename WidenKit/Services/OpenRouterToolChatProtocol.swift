import Foundation

struct OpenRouterToolCall: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var arguments: String
}

struct OpenRouterToolChatMessage: Equatable, Sendable {
    enum Role: String, Equatable, Sendable {
        case system
        case user
        case assistant
        case tool
    }

    var role: Role
    var content: String?
    var toolCalls: [OpenRouterToolCall]
    var toolCallID: String?
    var toolName: String?

    init(
        role: Role,
        content: String? = nil,
        toolCalls: [OpenRouterToolCall] = [],
        toolCallID: String? = nil,
        toolName: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
    }
}

struct OpenRouterToolDefinition: Equatable, Sendable {
    var name: String
    var description: String
    var parameters: JSONValue
}

struct OpenRouterToolChatRequestBuilder: Sendable {
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
        messages: [OpenRouterToolChatMessage],
        tools: [OpenRouterToolDefinition],
        capabilities: OpenRouterModelCapabilities,
        requireToolChoice: Bool = true
    ) throws -> BuiltRequest {
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map(messageBody),
            "tools": try tools.map(toolBody),
            "stream": false,
        ]
        if capabilities.supportsTemperature {
            body["temperature"] = 0
        }
        if capabilities.supportsMaxCompletionTokens {
            body["max_completion_tokens"] = cappedCompletionTokens(capabilities)
        } else if capabilities.supportsMaxTokens {
            body["max_tokens"] = cappedCompletionTokens(capabilities)
        } else {
            body["max_tokens"] = cappedCompletionTokens(capabilities)
        }
        if capabilities.supportsToolChoice, requireToolChoice {
            body["tool_choice"] = "required"
        }
        OpenRouterProviderPreferences.requiredPrivateRouting.apply(to: &body)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Widen", forHTTPHeaderField: "X-Title")
        request.setValue("enabled", forHTTPHeaderField: "X-OpenRouter-Metadata")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return BuiltRequest(request: request, mode: .promptOnlyJSON)
    }

    private func cappedCompletionTokens(_ capabilities: OpenRouterModelCapabilities) -> Int {
        min(Self.completionTokenBudget, max(16, capabilities.maximumCompletionTokens ?? Self.completionTokenBudget))
    }

    private func toolBody(_ definition: OpenRouterToolDefinition) throws -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": definition.name,
                "description": definition.description,
                "parameters": try definition.parameters.anyJSONValue(),
            ],
        ]
    }

    private func messageBody(_ message: OpenRouterToolChatMessage) -> [String: Any] {
        switch message.role {
        case .system, .user:
            return [
                "role": message.role.rawValue,
                "content": message.content ?? "",
            ]
        case .assistant:
            var body: [String: Any] = [
                "role": "assistant",
                "content": message.content ?? NSNull(),
            ]
            if !message.toolCalls.isEmpty {
                body["tool_calls"] = message.toolCalls.map { call in
                    [
                        "id": call.id,
                        "type": "function",
                        "function": [
                            "name": call.name,
                            "arguments": call.arguments,
                        ],
                    ]
                }
            }
            return body
        case .tool:
            var body: [String: Any] = [
                "role": "tool",
                "tool_call_id": message.toolCallID ?? "",
                "content": message.content ?? "",
            ]
            if let toolName = message.toolName {
                body["name"] = toolName
            }
            return body
        }
    }
}

struct OpenRouterToolChatParser: Sendable {
    struct ParsedTurn: Sendable {
        var content: String?
        var toolCalls: [OpenRouterToolCall]
        var metadata: OpenRouterGenerationMetadata
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                struct ToolCall: Decodable {
                    struct Function: Decodable {
                        let name: String?
                        let arguments: String?
                    }

                    let id: String?
                    let type: String?
                    let function: Function?
                }

                let role: String?
                let content: MessageContent?
                let refusal: String?
                let toolCalls: [ToolCall]?

                private enum CodingKeys: String, CodingKey {
                    case role
                    case content
                    case refusal
                    case toolCalls = "tool_calls"
                }
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
        let usage: Usage?
        let error: OpenRouterAPIErrorEnvelope.APIError?
        let openrouterMetadata: RouterMetadata?

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
            usage = try container.decodeIfPresent(Usage.self, forKey: .usage)
            error = try container.decodeIfPresent(OpenRouterAPIErrorEnvelope.APIError.self, forKey: .error)
            openrouterMetadata = try container.decodeIfPresent(RouterMetadata.self, forKey: .openrouterMetadata)
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

    private struct Usage: Decodable {
        struct CompletionDetails: Decodable {
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
    }

    private struct RouterMetadata: Decodable, Equatable, Sendable {
        struct Endpoints: Decodable, Equatable, Sendable {
            struct Endpoint: Decodable, Equatable, Sendable {
                let provider: String?
                let selected: Bool?
            }

            let available: [Endpoint]?
        }

        let endpoints: Endpoints?

        var selectedProvider: String? {
            endpoints?.available?.first { $0.selected == true }?.provider
        }
    }

    func parse(
        data: Data,
        response: HTTPURLResponse,
        requestedModelID: String,
        requestCount: Int,
        retryCount: Int,
        expectedCanonicalModelID: String? = nil
    ) throws -> ParsedTurn {
        if !(200..<300).contains(response.statusCode) {
            throw OpenRouterResponseParser.failure(
                from: data,
                response: response,
                requestedModelID: requestedModelID,
                attemptCount: requestCount
            )
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
            )
        }
        if let topError = completion.error {
            throw OpenRouterResponseParser.failure(
                apiError: topError,
                httpStatus: response.statusCode,
                completionID: completion.id,
                requestID: requestID,
                requestedModelID: requestedModelID,
                returnedModelID: completion.model,
                providerName: completion.provider ?? completion.openrouterMetadata?.selectedProvider,
                attemptCount: requestCount
            )
        }
        try OpenRouterCanonicalModelValidator.validate(
            returnedModelID: completion.model,
            expectedCanonicalModelID: expectedCanonicalModelID,
            requestedModelID: requestedModelID,
            httpStatus: response.statusCode,
            completionID: completion.id,
            requestID: requestID,
            providerName: completion.provider ?? completion.openrouterMetadata?.selectedProvider,
            attemptCount: requestCount
        )
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
            )
        }
        if let choiceError = choice.error {
            throw OpenRouterResponseParser.failure(
                apiError: choiceError,
                httpStatus: response.statusCode,
                completionID: completion.id,
                requestID: requestID,
                requestedModelID: requestedModelID,
                returnedModelID: completion.model,
                providerName: completion.provider ?? completion.openrouterMetadata?.selectedProvider,
                attemptCount: requestCount
            )
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
            )
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
            )
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
            )
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
            )
        }

        let toolCalls = try (choice.message?.toolCalls ?? []).map { call in
            guard call.type == nil || call.type == "function",
                let id = call.id?.trimmingCharacters(in: .whitespacesAndNewlines),
                !id.isEmpty,
                let name = call.function?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                !name.isEmpty,
                let arguments = call.function?.arguments
            else {
                throw OpenRouterFailure(
                    category: .malformedStructuredResponse,
                    message: "The cloud model returned a malformed tool call.",
                    httpStatus: response.statusCode,
                    completionID: completion.id,
                    requestID: requestID,
                    requestedModelID: requestedModelID,
                    returnedModelID: completion.model,
                    providerName: completion.provider ?? completion.openrouterMetadata?.selectedProvider,
                    attemptCount: requestCount
                )
            }
            return OpenRouterToolCall(id: id, name: name, arguments: arguments)
        }
        let content = choice.message?.content?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        guard !toolCalls.isEmpty || content != nil else {
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
            )
        }
        let metadata = OpenRouterGenerationMetadata(
            requestedModelID: requestedModelID,
            returnedModelID: completion.model,
            providerName: completion.provider ?? completion.openrouterMetadata?.selectedProvider,
            completionID: completion.id,
            requestID: requestID,
            structuredOutputMode: .promptOnlyJSON,
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
        return ParsedTurn(content: content, toolCalls: toolCalls, metadata: metadata)
    }
}

extension JSONValue {
    func anyJSONValue() throws -> Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .number(let value):
            return value
        case .string(let value):
            return value
        case .array(let values):
            return try values.map { try $0.anyJSONValue() }
        case .object(let values):
            return try values.reduce(into: [String: Any]()) { result, item in
                result[item.key] = try item.value.anyJSONValue()
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
