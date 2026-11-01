import Foundation
import Testing

@testable import WidenKit

@Suite("Cloud model profile")
struct CloudModelCatalogTests {
    @Test func productionProfilePinsDistinctRequestedAndReturnedIDs() {
        let profile = CloudModelCatalog.productionProfile
        #expect(!profile.requestedModelID.isEmpty)
        #expect(profile.expectedReturnedModelID?.isEmpty == false)
        #expect(profile.requestedModelID != profile.expectedReturnedModelID)
        #expect(!profile.displayName.isEmpty)
    }

    @Test func particleRequestIDComesFromParticlesOwnHeader() throws {
        let response = try #require(
            HTTPURLResponse(
                url: CloudModelProfile.particle.chatCompletionsURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["x-particle-request-id": "req-particle"]
            )
        )
        #expect(CloudSQLResponseParser.requestID(from: response, profile: .particle) == "req-particle")
    }

    @Test func particleProfileMatchesTheParticle1Contract() {
        let profile = CloudModelProfile.particle
        #expect(profile.provider == .particle)
        #expect(profile.displayName == "Particle-1")
        #expect(profile.chatCompletionsURL.absoluteString == "https://api.particle.ai/v1/chat/completions")
        #expect(profile.modelsURL?.absoluteString == "https://api.particle.ai/v1/models")
        #expect(profile.requestedModelID == "particle-1")
        #expect(profile.expectedReturnedModelID == "particle-ai/particle-1")
        #expect(profile.identityPolicy == .exactReturnedModelID)
        guard case .staticCapabilities(let capabilities) = profile.capabilityResolution else {
            Issue.record("Particle capabilities must be static")
            return
        }
        #expect(capabilities.supportsTools)
        #expect(capabilities.supportsToolChoice)
        #expect(capabilities.supportsResponseFormat)
        #expect(!capabilities.supportsStructuredOutputs)
        #expect(!capabilities.supportsTemperature)
        #expect(capabilities.supportsMaxCompletionTokens)
        #expect(!capabilities.supportsMaxTokens)
        #expect(capabilities.contextLength == 1_048_576)
        #expect(capabilities.maximumCompletionTokens == 131_072)
        #expect(capabilities.capabilitySource == .staticProfile)
        #expect(profile.pricing == CloudModelPricing(input: 0.25, cachedInput: 0.03, output: 1.00))
        #expect(!profile.reportsUsageCost)
        #expect(
            profile.policy(for: .agentTurn)
                == CloudCallSitePolicy(reasoningEffort: .high, maxCompletionTokens: 16_000, responseFormat: .none)
        )
        #expect(
            profile.policy(for: .oneShotSQL)
                == CloudCallSitePolicy(reasoningEffort: .high, maxCompletionTokens: 16_000, responseFormat: .jsonObject)
        )
        #expect(
            profile.policy(for: .connectivityProbe)
                == CloudCallSitePolicy(
                    reasoningEffort: ReasoningEffort.none,
                    maxCompletionTokens: 256,
                    responseFormat: .jsonObject
                )
        )
        #expect(
            profile.policy(for: .sessionTitle)
                == CloudCallSitePolicy(
                    reasoningEffort: ReasoningEffort.none,
                    maxCompletionTokens: 64,
                    responseFormat: .none
                )
        )
        #expect(profile.supportsReasoningEffort)
        #expect(profile.parallelToolCalls == true)
        #expect(profile.usesPromptCacheKey)
        #expect(!profile.echoesReasoningContent)
        #expect(!profile.sendsToolMessageName)
        #expect(!profile.usesOpenRouterRouting)
        #expect(profile.requestIDHeaderNames == ["X-Particle-Request-Id", "X-Request-Id", "Request-Id"])
        #expect(profile.requestTimeoutSeconds == 180)
        #expect(profile.resourceTimeoutSeconds == 300)
        #expect(profile.foreignAPIKeyPrefixes == ["sk-or-"])
        #expect(profile.evalAPIKeyEnvironmentVariable == "WIDEN_EVAL_PARTICLE_API_KEY")
    }

    @Test func promptCacheKeysAreFreshShortAndOnlyForProfilesThatUseThem() throws {
        let first = try #require(CloudModelProfile.particle.makePromptCacheKey())
        let second = try #require(CloudModelProfile.particle.makePromptCacheKey())

        #expect(first.hasPrefix("widen-"))
        #expect(first == first.lowercased())
        #expect(first.utf8.count <= 256)
        #expect(first != second)
        #expect(CloudModelProfile.openRouterGPT55.makePromptCacheKey() == nil)
    }

    @Test func defaultTransportsUseTheProfileTimeouts() {
        let particle = URLSessionTransport(timeoutsOf: .particle).sessionConfiguration
        #expect(particle.timeoutIntervalForRequest == 180)
        #expect(particle.timeoutIntervalForResource == 300)

        let openRouter = URLSessionTransport(timeoutsOf: .openRouterGPT55).sessionConfiguration
        #expect(openRouter.timeoutIntervalForRequest == 90)
        #expect(
            openRouter.timeoutIntervalForResource
                == URLSessionConfiguration.ephemeral.timeoutIntervalForResource
        )
    }

    @Test func openRouterProfileKeepsTheRequestSettingsTheAppAlwaysSent() {
        let profile = CloudModelProfile.openRouterGPT55
        #expect(profile.provider == .openRouter)
        #expect(profile.chatCompletionsURL.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(profile.requestedModelID == "openai/gpt-5.5")
        #expect(profile.expectedReturnedModelID == "openai/gpt-5.5-20260423")
        #expect(profile.identityPolicy == .openRouterCanonical)
        #expect(profile.capabilityResolution == .openRouterCatalog)
        #expect(profile.pricing == nil)
        #expect(profile.reportsUsageCost)
        #expect(
            profile.policy(for: .agentTurn)
                == CloudCallSitePolicy(reasoningEffort: nil, maxCompletionTokens: 2_048, responseFormat: .none)
        )
        #expect(
            profile.policy(for: .oneShotSQL)
                == CloudCallSitePolicy(
                    reasoningEffort: nil,
                    maxCompletionTokens: 2_048,
                    responseFormat: .strictJSONSchemaWhenAdvertised
                )
        )
        #expect(!profile.supportsReasoningEffort)
        #expect(profile.parallelToolCalls == nil)
        #expect(!profile.usesPromptCacheKey)
        #expect(!profile.echoesReasoningContent)
        #expect(profile.sendsToolMessageName)
        #expect(profile.usesOpenRouterRouting)
        #expect(profile.requestTimeoutSeconds == 90)
        #expect(profile.resourceTimeoutSeconds == nil)
        #expect(profile.foreignAPIKeyPrefixes == ["pai-"])
        #expect(profile.evalAPIKeyEnvironmentVariable == "WIDEN_EVAL_OPENROUTER_API_KEY")
    }

    @Test func openRouterOneShotRequestMatchesThePreProfileRequest() throws {
        var capabilities = CloudModelCapabilities.conservative()
        capabilities.supportsStructuredOutputs = true
        capabilities.supportsTemperature = true
        capabilities.supportsMaxCompletionTokens = true
        capabilities.maximumCompletionTokens = 4_096

        let built = try ChatCompletionRequestBuilder(profile: .openRouterGPT55).build(
            apiKey: "test-key",
            instructions: "instructions",
            prompt: "prompt",
            capabilities: capabilities
        )
        let body = try Self.jsonBody(built.request)

        #expect(built.request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(built.request.httpMethod == "POST")
        #expect(built.request.allHTTPHeaderFields == Self.openRouterCompletionHeaders)
        #expect(
            Set(body.keys) == [
                "model", "messages", "stream", "temperature", "max_completion_tokens",
                "response_format", "provider",
            ]
        )
        #expect(body["model"] as? String == "openai/gpt-5.5")
        #expect(body["max_completion_tokens"] as? Int == 2_048)
        try OpenRouterTestSupport.expectPrivateRouting(inBody: body)
    }

    @Test func openRouterToolRequestMatchesThePreProfileRequest() throws {
        var capabilities = CloudModelCapabilities.conservative()
        capabilities.supportsTools = true
        capabilities.supportsToolChoice = true
        capabilities.supportsTemperature = true
        capabilities.supportsMaxCompletionTokens = true
        capabilities.maximumCompletionTokens = 4_096

        let built = try ChatToolRequestBuilder(profile: .openRouterGPT55).build(
            apiKey: "test-key",
            messages: [
                ChatToolMessage(role: .user, content: "question"),
                ChatToolMessage(
                    role: .tool,
                    content: "{}",
                    toolCallID: "call-1",
                    toolName: "search_schema"
                ),
            ],
            // An agent turn always offers at least the terminal tool.
            tools: Self.toolDefinitions(["search_schema"]),
            capabilities: capabilities
        )
        let body = try Self.jsonBody(built.request)
        let messages = try #require(body["messages"] as? [[String: Any]])

        #expect(built.request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(built.request.allHTTPHeaderFields == Self.openRouterCompletionHeaders)
        #expect(
            Set(body.keys) == [
                "model", "messages", "tools", "stream", "temperature", "max_completion_tokens",
                "tool_choice", "provider",
            ]
        )
        #expect(body["tool_choice"] as? String == "required")
        #expect(body["max_completion_tokens"] as? Int == 2_048)
        #expect(messages.last?["name"] as? String == "search_schema")
        #expect(built.reasoningEffort == nil)
        #expect(built.responseFormatType == nil)
        try OpenRouterTestSupport.expectPrivateRouting(inBody: body)
    }

    @Test func particleToolRequestDefaultsSendTheAgentTurnBody() throws {
        let built = try ChatToolRequestBuilder(profile: .particle).build(
            apiKey: "pai-test",
            messages: [ChatToolMessage(role: .user, content: "question")],
            tools: Self.toolDefinitions(["search_schema", "submit_text_to_sql_result"]),
            capabilities: Self.particleCapabilities,
            options: ChatRequestOptions(promptCacheKey: "widen-run")
        )
        let body = try Self.jsonBody(built.request)

        #expect(
            Set(body.keys) == [
                "model", "messages", "tools", "stream", "max_completion_tokens", "tool_choice",
                "parallel_tool_calls", "reasoning_effort", "prompt_cache_key",
            ]
        )
        #expect(try Self.toolNames(in: body) == ["search_schema", "submit_text_to_sql_result"])
        #expect(body["tool_choice"] as? String == "required")
        #expect(body["parallel_tool_calls"] as? Bool == true)
        #expect(body["max_completion_tokens"] as? Int == 16_000)
        #expect(body["reasoning_effort"] as? String == "high")
        #expect(body["prompt_cache_key"] as? String == "widen-run")
        #expect(built.reasoningEffort == "high")
        #expect(built.responseFormatType == nil)
    }

    @Test func namedToolChoiceSendsOneToolWithoutParallelCalls() throws {
        let built = try ChatToolRequestBuilder(profile: .particle).build(
            apiKey: "pai-test",
            messages: [ChatToolMessage(role: .user, content: "question")],
            tools: Self.toolDefinitions(["search_schema", "submit_text_to_sql_result"]),
            capabilities: Self.particleCapabilities,
            options: ChatRequestOptions(
                toolChoice: .function(name: "submit_text_to_sql_result"),
                parallelToolCalls: false,
                toolNames: ["submit_text_to_sql_result"]
            )
        )
        let body = try Self.jsonBody(built.request)
        let toolChoice = try #require(body["tool_choice"] as? [String: Any])

        #expect(try Self.toolNames(in: body) == ["submit_text_to_sql_result"])
        #expect(toolChoice["type"] as? String == "function")
        #expect((toolChoice["function"] as? [String: Any])?["name"] as? String == "submit_text_to_sql_result")
        #expect(Set(toolChoice.keys) == ["type", "function"])
        #expect(body["parallel_tool_calls"] as? Bool == false)
    }

    @Test(arguments: [
        (ChatToolChoice.omitted, nil as String?),
        (.auto, "auto"),
        (.required, "required"),
    ])
    func stringToolChoicesAreSentAsTheyAre(choice: ChatToolChoice, sent: String?) throws {
        let built = try ChatToolRequestBuilder(profile: .particle).build(
            apiKey: "pai-test",
            messages: [ChatToolMessage(role: .user, content: "question")],
            tools: Self.toolDefinitions(["search_schema"]),
            capabilities: Self.particleCapabilities,
            options: ChatRequestOptions(toolChoice: choice)
        )
        let body = try Self.jsonBody(built.request)

        #expect(body["tool_choice"] as? String == sent)
        #expect(body.keys.contains("tool_choice") == (sent != nil))
        #expect(body["parallel_tool_calls"] as? Bool == true)
    }

    @Test func namedToolChoiceFallsBackWithoutToolChoiceSupport() throws {
        var capabilities = CloudModelCapabilities.conservative()
        capabilities.supportsTools = true
        capabilities.supportsMaxCompletionTokens = true

        let built = try ChatToolRequestBuilder(profile: .openRouterGPT55).build(
            apiKey: "test-key",
            messages: [ChatToolMessage(role: .user, content: "question")],
            tools: Self.toolDefinitions(["search_schema", "submit_text_to_sql_result"]),
            capabilities: capabilities,
            options: ChatRequestOptions(toolChoice: .function(name: "submit_text_to_sql_result"))
        )
        let body = try Self.jsonBody(built.request)

        // Like `required`, the named choice is not sent to a model whose
        // catalog entry lists no tool_choice support.
        #expect(body["tool_choice"] == nil)
        #expect(try Self.toolNames(in: body) == ["search_schema", "submit_text_to_sql_result"])
    }

    @Test func requestWithoutToolsOmitsEveryToolField() throws {
        for (tools, toolNames) in [
            ([ChatToolDefinition](), nil as Set<String>?),
            (Self.toolDefinitions(["search_schema"]), Set(["describe_tables"])),
        ] {
            let built = try ChatToolRequestBuilder(profile: .particle).build(
                apiKey: "pai-test",
                messages: [ChatToolMessage(role: .user, content: "question")],
                tools: tools,
                capabilities: Self.particleCapabilities,
                options: ChatRequestOptions(
                    toolChoice: .function(name: "describe_tables"),
                    parallelToolCalls: false,
                    toolNames: toolNames
                )
            )
            let body = try Self.jsonBody(built.request)

            #expect(body["tools"] == nil)
            #expect(body["tool_choice"] == nil)
            #expect(body["parallel_tool_calls"] == nil)
            #expect(body["model"] as? String == "particle-1")
        }
    }

    @Test func jsonObjectResponseFormatIsSentOnlyWhenSupported() throws {
        let builder = ChatToolRequestBuilder(profile: .particle)
        let options = ChatRequestOptions(toolChoice: .omitted, responseFormat: .jsonObject)

        let supported = try builder.build(
            apiKey: "pai-test",
            messages: [ChatToolMessage(role: .user, content: "question")],
            tools: [],
            capabilities: Self.particleCapabilities,
            options: options
        )
        let supportedBody = try Self.jsonBody(supported.request)
        #expect((supportedBody["response_format"] as? [String: Any])?["type"] as? String == "json_object")
        #expect(supported.responseFormatType == "json_object")
        #expect(supported.mode == .promptOnlyJSON)

        var capabilities = Self.particleCapabilities
        capabilities.supportsResponseFormat = false
        let unsupported = try builder.build(
            apiKey: "pai-test",
            messages: [ChatToolMessage(role: .user, content: "question")],
            tools: [],
            capabilities: capabilities,
            options: options
        )
        #expect(try Self.jsonBody(unsupported.request)["response_format"] == nil)
        #expect(unsupported.responseFormatType == nil)
    }

    @Test func requestOptionsOverrideEffortTokensAndCacheKey() throws {
        let options = ChatRequestOptions(
            reasoningEffort: ReasoningEffort.none,
            maximumCompletionTokens: 1_000,
            promptCacheKey: "widen-critic"
        )
        let particle = try ChatToolRequestBuilder(profile: .particle).build(
            apiKey: "pai-test",
            messages: [ChatToolMessage(role: .user, content: "question")],
            tools: Self.toolDefinitions(["search_schema"]),
            capabilities: Self.particleCapabilities,
            options: options
        )
        let particleBody = try Self.jsonBody(particle.request)
        #expect(particleBody["reasoning_effort"] as? String == "none")
        #expect(particleBody["max_completion_tokens"] as? Int == 1_000)
        #expect(particleBody["prompt_cache_key"] as? String == "widen-critic")
        #expect(particle.reasoningEffort == "none")

        // The model's own maximum still caps an override.
        let capped = try ChatToolRequestBuilder(profile: .particle).build(
            apiKey: "pai-test",
            messages: [ChatToolMessage(role: .user, content: "question")],
            tools: Self.toolDefinitions(["search_schema"]),
            capabilities: Self.particleCapabilities,
            options: ChatRequestOptions(maximumCompletionTokens: 500_000)
        )
        #expect(try Self.jsonBody(capped.request)["max_completion_tokens"] as? Int == 131_072)

        // OpenRouter sends neither reasoning_effort nor prompt_cache_key.
        var capabilities = CloudModelCapabilities.conservative()
        capabilities.supportsTools = true
        capabilities.supportsToolChoice = true
        capabilities.supportsMaxCompletionTokens = true
        capabilities.maximumCompletionTokens = 4_096
        let openRouter = try ChatToolRequestBuilder(profile: .openRouterGPT55).build(
            apiKey: "test-key",
            messages: [ChatToolMessage(role: .user, content: "question")],
            tools: Self.toolDefinitions(["search_schema"]),
            capabilities: capabilities,
            options: options
        )
        let openRouterBody = try Self.jsonBody(openRouter.request)
        #expect(openRouterBody["reasoning_effort"] == nil)
        #expect(openRouterBody["prompt_cache_key"] == nil)
        #expect(openRouterBody["max_completion_tokens"] as? Int == 1_000)
        #expect(openRouter.reasoningEffort == nil)
    }

    @Test func openRouterCatalogRequestsAreSignedLikeBefore() async throws {
        let transport = RecordingTransport { request, _ in
            (Data(#"{"data":[]}"#.utf8), RecordingTransport.response(to: request))
        }
        let service = OpenRouterModelCatalogService(
            profile: .openRouterGPT55,
            transport: transport,
            cacheURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("widen-catalog-\(UUID().uuidString).json")
        )

        _ = try await service.availableModels(apiKey: "test-key", forceRefresh: true)

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/models/user")
        #expect(request.httpMethod == "GET")
        #expect(
            request.allHTTPHeaderFields == [
                "Authorization": "Bearer test-key",
                "X-Title": "Widen",
            ]
        )
    }

    @Test func evalProfileIsInferredFromTheRequestedModel() throws {
        let particle = try #require(CloudModelCatalog.profile(forRequestedModelID: "particle-1"))
        #expect(particle == .particle)
        #expect(particle.provider == .particle)
        #expect(particle.baseURL.host == "api.particle.ai")
        #expect(particle.expectedReturnedModelID == "particle-ai/particle-1")

        let gpt55 = try #require(CloudModelCatalog.profile(forRequestedModelID: "openai/gpt-5.5"))
        #expect(
            gpt55
                == .openRouter(
                    requestedModelID: "openai/gpt-5.5",
                    expectedReturnedModelID: "openai/gpt-5.5-20260423"
                )
        )
        #expect(gpt55.provider == .openRouter)
        #expect(gpt55.baseURL.host == "openrouter.ai")

        // Other OpenRouter models enforce no dated version, including the
        // dated GPT-5.5 ID itself when it is requested directly.
        for id in ["vendor/other-model", "openai/gpt-5.5-20260423", "meta-llama/llama-3-70b:nitro"] {
            let profile = try #require(CloudModelCatalog.profile(forRequestedModelID: id), "\(id)")
            #expect(profile.provider == .openRouter)
            #expect(profile.requestedModelID == id)
            #expect(profile.expectedReturnedModelID == nil)
        }

        for junk in [
            "", "junk", "gpt-5.5", "Particle-1", "particle-1 ", "/gpt-5.5", "openai/",
            "openai/gpt 5.5", "particle-ai/particle-1", "Particle-AI/particle-1",
        ] {
            #expect(CloudModelCatalog.profile(forRequestedModelID: junk) == nil, "\(junk)")
        }
    }

    @Test func evalsEnforceTheProductionReturnedModelForThePinnedModel() throws {
        let production = CloudModelCatalog.productionProfile
        let profile = try #require(
            CloudModelCatalog.profile(forRequestedModelID: production.requestedModelID)
        )
        #expect(profile.provider == production.provider)
        #expect(profile.baseURL == production.baseURL)
        #expect(profile.expectedReturnedModelID == production.expectedReturnedModelID)
    }

    @Test func reasoningEffortOverrideChangesOnlyTheSQLCallSites() {
        let profile = CloudModelProfile.particle.overridingReasoningEffort(.low)

        for callSite in [CloudCallSite.agentTurn, .oneShotSQL] {
            var expected = CloudModelProfile.particle.policy(for: callSite)
            expected.reasoningEffort = .low
            #expect(profile.policy(for: callSite) == expected)
        }
        for callSite in [CloudCallSite.connectivityProbe, .sessionTitle] {
            #expect(profile.policy(for: callSite) == CloudModelProfile.particle.policy(for: callSite))
        }
        var unchanged = profile
        unchanged.callSites = CloudModelProfile.particle.callSites
        #expect(unchanged == .particle)
    }

    private static let openRouterCompletionHeaders = [
        "Authorization": "Bearer test-key",
        "Content-Type": "application/json",
        "X-Title": "Widen",
        "X-OpenRouter-Metadata": "enabled",
    ]

    private static func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static var particleCapabilities: CloudModelCapabilities {
        guard case .staticCapabilities(let capabilities) = CloudModelProfile.particle.capabilityResolution
        else { preconditionFailure("Particle capabilities are static") }
        return capabilities
    }

    private static func toolDefinitions(_ names: [String]) -> [ChatToolDefinition] {
        names.map { name in
            ChatToolDefinition(
                name: name,
                description: "The \(name) tool.",
                parameters: ["type": "object", "properties": [:]]
            )
        }
    }

    private static func toolNames(in body: [String: Any]) throws -> [String] {
        let tools = try #require(body["tools"] as? [[String: Any]])
        return tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
    }
}
