import Foundation

struct ChatToolCall: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var arguments: String
}

struct ChatToolMessage: Equatable, Sendable {
    enum Role: String, Equatable, Sendable {
        case system
        case user
        case assistant
        case tool
    }

    var role: Role
    var content: String?
    var toolCalls: [ChatToolCall]
    var toolCallID: String?
    var toolName: String?

    init(
        role: Role,
        content: String? = nil,
        toolCalls: [ChatToolCall] = [],
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

struct ChatToolDefinition: Equatable, Sendable {
    var name: String
    var description: String
    var parameters: JSONValue
}

struct ChatToolRequestBuilder: Sendable {
    let profile: CloudModelProfile

    init(profile: CloudModelProfile) {
        self.profile = profile
    }

    struct BuiltRequest: Sendable {
        var request: URLRequest
        var mode: StructuredOutputMode
    }

    func build(
        apiKey: String,
        messages: [ChatToolMessage],
        tools: [ChatToolDefinition],
        capabilities: CloudModelCapabilities,
        requireToolChoice: Bool = true,
        promptCacheKey: String? = nil
    ) throws -> BuiltRequest {
        let policy = profile.policy(for: .agentTurn)
        var body: [String: Any] = [
            "model": profile.requestedModelID,
            "messages": messages.map(messageBody),
            "tools": try tools.map(toolBody),
            "stream": false,
        ]
        if capabilities.supportsTemperature {
            body["temperature"] = 0
        }
        if capabilities.supportsMaxCompletionTokens {
            body["max_completion_tokens"] = cappedCompletionTokens(policy, capabilities)
        } else if capabilities.supportsMaxTokens {
            body["max_tokens"] = cappedCompletionTokens(policy, capabilities)
        } else {
            body["max_tokens"] = cappedCompletionTokens(policy, capabilities)
        }
        if capabilities.supportsToolChoice, requireToolChoice {
            body["tool_choice"] = "required"
        }
        if let parallelToolCalls = profile.parallelToolCalls {
            body["parallel_tool_calls"] = parallelToolCalls
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
        return BuiltRequest(request: request, mode: .promptOnlyJSON)
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

    private func toolBody(_ definition: ChatToolDefinition) throws -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": definition.name,
                "description": definition.description,
                "parameters": try definition.parameters.anyJSONValue(),
            ],
        ]
    }

    private func messageBody(_ message: ChatToolMessage) -> [String: Any] {
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
            if profile.sendsToolMessageName, let toolName = message.toolName {
                body["name"] = toolName
            }
            return body
        }
    }
}

struct ChatToolParser: Sendable {
    struct ParsedTurn: Sendable {
        var content: String?
        var toolCalls: [ChatToolCall]
        var metadata: CloudGenerationMetadata
    }

    let profile: CloudModelProfile

    init(profile: CloudModelProfile) {
        self.profile = profile
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

    func parse(
        data: Data,
        response: HTTPURLResponse,
        requestedModelID: String,
        requestCount: Int,
        retryCount: Int,
        expectedCanonicalModelID: String? = nil
    ) throws -> ParsedTurn {
        let reportedUsage = CloudSQLResponseParser.reportedUsage(from: data, profile: profile)
        if !(200..<300).contains(response.statusCode) {
            throw CloudSQLResponseParser.failure(
                from: data,
                response: response,
                requestedModelID: requestedModelID,
                attemptCount: requestCount,
                profile: profile
            ).withReportedUsage(reportedUsage)
        }
        let requestID = CloudSQLResponseParser.requestID(from: response, profile: profile)
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
            throw CloudSQLResponseParser.failure(
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
            throw CloudSQLResponseParser.failure(
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

        let toolCalls = try (choice.message?.toolCalls ?? []).map { call in
            guard call.type == nil || call.type == "function",
                let id = call.id?.trimmingCharacters(in: .whitespacesAndNewlines),
                !id.isEmpty,
                let name = call.function?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                !name.isEmpty,
                let arguments = call.function?.arguments
            else {
                throw CloudRequestFailure(
                    category: .malformedStructuredResponse,
                    message: "The cloud model returned a malformed tool call.",
                    httpStatus: response.statusCode,
                    completionID: completion.id,
                    requestID: requestID,
                    requestedModelID: requestedModelID,
                    returnedModelID: completion.model,
                    providerName: completion.provider ?? completion.openrouterMetadata?.selectedProvider,
                    attemptCount: requestCount
                ).withReportedUsage(reportedUsage)
            }
            return ChatToolCall(id: id, name: name, arguments: arguments)
        }
        let content = choice.message?.content?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        guard !toolCalls.isEmpty || content != nil else {
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
        } catch let failure as CloudRequestFailure {
            throw failure.withReportedUsage(reportedUsage)
        }
        let usage = completion.usage?.priced(by: profile)
        let metadata = CloudGenerationMetadata(
            providerID: profile.provider.rawValue,
            requestedModelID: requestedModelID,
            returnedModelID: completion.model,
            providerName: completion.provider ?? completion.openrouterMetadata?.selectedProvider,
            completionID: completion.id,
            requestID: requestID,
            structuredOutputMode: .promptOnlyJSON,
            reasoningEffort: profile.policy(for: .agentTurn).reasoningEffort?.rawValue,
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
