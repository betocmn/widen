import Foundation
import Testing

@testable import WidenKit

@Suite("OpenRouter reliability")
struct OpenRouterSQLGeneratorTests {
    private final class StubTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [Result<(Data, HTTPURLResponse), Error>]
        private var recorded: [URLRequest] = []

        init(_ results: [Result<(Data, HTTPURLResponse), Error>]) {
            queue = results
        }

        var requests: [URLRequest] {
            lock.withLock { recorded }
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            try lock.withLock {
                recorded.append(request)
                guard !queue.isEmpty else { throw URLError(.badServerResponse) }
                return try queue.removeFirst().get()
            }
        }
    }

    private final class CancellationAwareTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [URLRequest] = []

        var requests: [URLRequest] {
            lock.withLock { recorded }
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { recorded.append(request) }
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            throw URLError(.cancelled)
        }
    }

    private final class DelayedTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private let result: (Data, HTTPURLResponse)
        private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        private var recorded: [URLRequest] = []

        init(result: (Data, HTTPURLResponse)) {
            self.result = result
        }

        var requests: [URLRequest] {
            lock.withLock { recorded }
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { recorded.append(request) }
            return try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    self.continuation = continuation
                }
            }
        }

        func complete() {
            let continuation = lock.withLock {
                let continuation = self.continuation
                self.continuation = nil
                return continuation
            }
            continuation?.resume(returning: result)
        }
    }

    private static let chatEndpoint = URL(string: "https://openrouter.test/api/v1/chat/completions")!
    private static let apiBase = URL(string: "https://openrouter.test/api/v1")!
    private static let modelID = "openai/gpt-5.5"

    private let goodContent = """
        {"sql":"SELECT id FROM public.users LIMIT 100","explanation":"Lists user ids.","assumptions":["All users wanted"],"referencedTables":["public.users"],"confidence":0.9,"riskLevel":"low","needsClarification":false,"clarificationQuestion":null}
        """

    @Test func catalogUsesAuthenticatedModelsUserAndDecodesCapabilities() async throws {
        let transport = StubTransport([
            .success((catalogResponse(), response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200)))
        ])
        let service = catalogService(transport: transport)

        let models = try await service.availableModels(apiKey: "secret-key", forceRefresh: true)

        #expect(transport.requests.first?.url?.path == "/api/v1/models/user")
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")
        let model = try #require(models.first)
        #expect(model.requestedID == Self.modelID)
        #expect(model.id == Self.modelID)
        #expect(model.canonicalModelID == "openai/gpt-5.5")
        #expect(model.displayName == "GPT-5.5")
        #expect(model.contextLength == 128_000)
        #expect(model.maximumCompletionTokens == 4096)
        #expect(model.supportedParameters.contains("response_format"))
        #expect(model.pricing?.prompt == "0.000001")
        #expect(model.expiration == "2027-01-01")
        #expect(model.isAvailableToAPIKey)
        #expect(model.capabilities.supportsResponseFormat)
        #expect(model.capabilities.supportsStructuredOutputs)
        #expect(model.capabilities.supportsTools)
        #expect(model.capabilities.supportsToolChoice)
        #expect(model.capabilities.supportsTemperature)
        #expect(model.capabilities.supportsSeed)
        #expect(model.capabilities.supportsMaxCompletionTokens)
        #expect(model.capabilities.contextLength == 128_000)
    }

    @Test func customModelFallsBackToSingleModelLookup() async throws {
        let transport = StubTransport([
            .success((catalogResponse(id: "openai/other"), response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200))),
            .success((singleModelResponse(id: "custom/model"), response(url: Self.apiBase.appendingPathComponent("model/custom/model"), status: 200))),
        ])
        let service = catalogService(transport: transport)

        let metadata = await service.metadata(apiKey: "secret-key", modelID: "custom/model", forceRefresh: true)

        #expect(transport.requests.map { $0.url?.path } == ["/api/v1/models/user", "/api/v1/model/custom/model"])
        #expect(metadata?.requestedID == "custom/model")
        #expect(metadata?.isAvailableToAPIKey == false)
        #expect(metadata?.capabilitySource == .singleModelLookup)
    }

    @Test func catalogCacheHitsExpiresFallsBackStaleAndInvalidates() async throws {
        let cacheURL = temporaryCacheURL()
        let transport = StubTransport([
            .success((catalogResponse(id: Self.modelID), response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200))),
            .success((catalogResponse(id: "openai/second"), response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200))),
            .failure(URLError(.networkConnectionLost)),
            .success((catalogResponse(id: Self.modelID), response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200))),
        ])
        let service = catalogService(transport: transport, cacheURL: cacheURL, ttl: 60)

        _ = try await service.availableModels(apiKey: "secret-key")
        _ = try await service.availableModels(apiKey: "secret-key")
        #expect(transport.requests.count == 1)

        await service.invalidate(apiKey: "secret-key")
        let refreshed = try await service.availableModels(apiKey: "secret-key")
        #expect(refreshed.first?.id == "openai/second")
        #expect(transport.requests.count == 2)

        let expiring = catalogService(transport: transport, cacheURL: cacheURL, ttl: -1)
        let stale = try await expiring.availableModels(apiKey: "secret-key")
        #expect(stale.first?.capabilitySource == .staleCache)
        #expect(transport.requests.count == 3)

        _ = try await expiring.availableModels(apiKey: "another-key")
        #expect(transport.requests.count == 4)

        let cacheText = try String(contentsOf: cacheURL, encoding: .utf8)
        #expect(!cacheText.contains("secret-key"))
        #expect(cacheText.contains(OpenRouterModelCatalogService.apiKeyFingerprint("secret-key")))
    }

    @Test func authFailureDoesNotFallBackToStaleCatalog() async throws {
        let cacheURL = temporaryCacheURL()
        let primingTransport = StubTransport([
            .success((catalogResponse(id: Self.modelID), response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200)))
        ])
        let primingService = catalogService(transport: primingTransport, cacheURL: cacheURL, ttl: 60)
        _ = try await primingService.availableModels(apiKey: "secret-key")

        let authFailureTransport = StubTransport([
            .success((
                errorResponse(errorType: "invalid_api_key", message: "Invalid API key"),
                response(url: Self.apiBase.appendingPathComponent("models/user"), status: 401)
            ))
        ])
        let expiredService = catalogService(transport: authFailureTransport, cacheURL: cacheURL, ttl: -1)

        do {
            _ = try await expiredService.availableModels(apiKey: "secret-key")
            Issue.record("expected authentication failure")
        } catch let failure as OpenRouterFailure {
            #expect(failure.category == .authentication)
        }
        #expect(authFailureTransport.requests.count == 1)
    }

    @Test func cancellingOneCatalogWaiterDoesNotCancelSharedRefresh() async throws {
        let transport = DelayedTransport(
            result: (
                catalogResponse(),
                response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200)
            )
        )
        let service = catalogService(transport: transport)
        let first = Task {
            try await service.availableModels(apiKey: "secret-key", forceRefresh: true)
        }
        while transport.requests.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let second = Task {
            try await service.availableModels(apiKey: "secret-key", forceRefresh: true)
        }
        try await Task.sleep(nanoseconds: 10_000_000)

        first.cancel()
        try await Task.sleep(nanoseconds: 10_000_000)
        transport.complete()

        await expectCancellation(first)
        let models = try await second.value
        #expect(models.first?.id == Self.modelID)
        #expect(transport.requests.count == 1)
    }

    @Test func cancelledMetadataLookupDoesNotReturnStaleCache() async throws {
        let cacheURL = temporaryCacheURL()
        let primingTransport = StubTransport([
            .success((catalogResponse(), response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200)))
        ])
        let primingService = catalogService(transport: primingTransport, cacheURL: cacheURL)
        _ = try await primingService.availableModels(apiKey: "secret-key")

        let transport = CancellationAwareTransport()
        let service = catalogService(transport: transport, cacheURL: cacheURL)
        let lookup = Task {
            await service.metadata(apiKey: "secret-key", modelID: Self.modelID, forceRefresh: true)
        }
        while transport.requests.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        lookup.cancel()

        let metadata = await lookup.value
        #expect(metadata == nil)
    }

    @Test func invalidatingCanonicalModelIDRemovesCachedCapabilities() async throws {
        let transport = StubTransport([
            .success((
                catalogResponse(id: "provider/alias", canonicalID: Self.modelID),
                response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200)
            ))
        ])
        let service = catalogService(transport: transport)
        _ = try await service.availableModels(apiKey: "secret-key")

        let cached = await service.metadata(
            apiKey: "secret-key",
            modelID: Self.modelID,
            allowStaleFallback: false
        )
        #expect(cached?.id == "provider/alias")
        #expect(cached?.canonicalModelID == Self.modelID)

        await service.invalidate(apiKey: "secret-key", modelID: Self.modelID)
        let invalidated = await service.metadata(
            apiKey: "secret-key",
            modelID: Self.modelID,
            allowStaleFallback: false
        )

        #expect(invalidated == nil)
    }

    @Test func invalidatingModelMarksCatalogStaleForAuthenticatedRefresh() async throws {
        let transport = StubTransport([
            .success((
                catalogResponse(id: Self.modelID),
                response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200)
            )),
            .success((
                catalogResponse(id: Self.modelID, parameters: ["max_tokens"]),
                response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200)
            )),
        ])
        let service = catalogService(transport: transport, ttl: 60)
        let cached = await service.metadata(
            apiKey: "secret-key",
            modelID: Self.modelID,
            allowStaleFallback: false
        )
        #expect(cached?.capabilities.supportsStructuredOutputs == true)

        await service.invalidate(apiKey: "secret-key", modelID: Self.modelID)
        let refreshed = await service.metadata(
            apiKey: "secret-key",
            modelID: Self.modelID,
            allowStaleFallback: false
        )

        #expect(refreshed?.capabilities.supportsStructuredOutputs == false)
        #expect(refreshed?.capabilities.supportsMaxTokens == true)
        #expect(transport.requests.map { $0.url?.path } == ["/api/v1/models/user", "/api/v1/models/user"])
    }

    @Test func requestBuilderKeepsPromptModeTokenCapWhenCapabilitiesUnknown() throws {
        let built = try OpenRouterRequestBuilder(endpoint: Self.chatEndpoint).build(
            apiKey: "test-key",
            model: Self.modelID,
            instructions: "instructions",
            prompt: "prompt",
            capabilities: .conservative()
        )
        let body = try jsonBody(built.request)

        #expect(built.mode == .promptOnlyJSON)
        #expect(body["response_format"] == nil)
        #expect(body["temperature"] == nil)
        #expect(body["max_tokens"] as? Int == OpenRouterRequestBuilder.completionTokenBudget)
        #expect(body["max_completion_tokens"] == nil)
        #expect(body["provider"] == nil)
        #expect(built.request.value(forHTTPHeaderField: "X-OpenRouter-Metadata") == "enabled")
    }

    @Test func requestBuilderUsesStrictModeOnlyWhenAdvertised() throws {
        var capabilities = OpenRouterModelCapabilities.conservative()
        capabilities.supportsResponseFormat = true
        capabilities.supportsStructuredOutputs = true
        capabilities.supportsTemperature = true
        capabilities.supportsMaxTokens = true
        capabilities.supportsMaxCompletionTokens = true
        capabilities.maximumCompletionTokens = 32

        let built = try OpenRouterRequestBuilder(endpoint: Self.chatEndpoint).build(
            apiKey: "test-key",
            model: Self.modelID,
            instructions: "instructions",
            prompt: "prompt",
            capabilities: capabilities
        )
        let body = try jsonBody(built.request)
        let provider = body["provider"] as? [String: Any]

        #expect(built.mode == .strictJSONSchema)
        #expect(body["response_format"] != nil)
        #expect(provider?["require_parameters"] as? Bool == true)
        #expect(body["temperature"] as? Int == 0)
        #expect(body["max_completion_tokens"] as? Int == 32)
        #expect(body["max_tokens"] == nil)
    }

    @Test func strictSchemaOmitsUnadvertisedTokenCaps() throws {
        var capabilities = OpenRouterModelCapabilities.conservative()
        capabilities.supportsStructuredOutputs = true

        let built = try OpenRouterRequestBuilder(endpoint: Self.chatEndpoint).build(
            apiKey: "test-key",
            model: Self.modelID,
            instructions: "instructions",
            prompt: "prompt",
            capabilities: capabilities
        )
        let body = try jsonBody(built.request)

        #expect(built.mode == .strictJSONSchema)
        #expect(body["provider"] != nil)
        #expect(body["max_tokens"] == nil)
        #expect(body["max_completion_tokens"] == nil)
    }

    @Test func responseFormatWithoutStructuredOutputsUsesPromptMode() throws {
        var capabilities = OpenRouterModelCapabilities.conservative()
        capabilities.supportsResponseFormat = true
        capabilities.supportsTemperature = true

        let built = try OpenRouterRequestBuilder(endpoint: Self.chatEndpoint).build(
            apiKey: "test-key",
            model: Self.modelID,
            instructions: "instructions",
            prompt: "prompt",
            capabilities: capabilities
        )
        let body = try jsonBody(built.request)

        #expect(built.mode == .promptOnlyJSON)
        #expect(body["response_format"] == nil)
        #expect(body["provider"] == nil)
        #expect(body["temperature"] as? Int == 0)
        #expect(body["max_tokens"] as? Int == OpenRouterRequestBuilder.completionTokenBudget)
    }

    @Test func maxTokensFallbackIsUsedOnlyWhenAdvertised() throws {
        var capabilities = OpenRouterModelCapabilities.conservative()
        capabilities.supportsMaxTokens = true
        capabilities.maximumCompletionTokens = 16_000

        let body = try jsonBody(
            OpenRouterRequestBuilder(endpoint: Self.chatEndpoint).build(
                apiKey: "test-key",
                model: Self.modelID,
                instructions: "instructions",
                prompt: "prompt",
                capabilities: capabilities
            ).request
        )

        #expect(body["max_tokens"] as? Int == OpenRouterRequestBuilder.completionTokenBudget)
        #expect(body["max_completion_tokens"] == nil)
    }

    @Test func noResponseFormatFallbackRequestIsIssued() async throws {
        let transport = StubTransport([
            .success((catalogResponse(), response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200))),
            .success((
                errorResponse(errorType: "unsupported_parameter", message: "response_format is not supported"),
                response(url: Self.chatEndpoint, status: 400)
            )),
        ])
        let generator = makeGenerator(transport: transport)

        do {
            _ = try await generator.generateSQL(
                question: "show users",
                schema: makeSchema(),
                config: SQLGenerationConfig()
            )
            Issue.record("expected unsupported feature")
        } catch let failure as OpenRouterFailure {
            #expect(failure.category == .unsupportedFeature)
        }

        #expect(transport.requests.map { $0.url?.path } == ["/api/v1/models/user", "/api/v1/chat/completions"])
    }

    @Test func parserHandlesStringAndContentParts() throws {
        let parser = OpenRouterResponseParser()
        let stringResult = try parser.parse(
            data: chatResponse(content: goodContent),
            response: response(url: Self.chatEndpoint, status: 200, headers: ["X-Request-Id": "req-1"]),
            requestedModelID: Self.modelID,
            mode: .strictJSONSchema,
            requestCount: 1,
            retryCount: 0
        )
        let partsResult = try parser.parse(
            data: chatResponse(content: [["type": "text", "text": goodContent]]),
            response: response(url: Self.chatEndpoint, status: 200),
            requestedModelID: Self.modelID,
            mode: .strictJSONSchema,
            requestCount: 1,
            retryCount: 0
        )

        #expect(stringResult.result.sql == "SELECT id FROM public.users LIMIT 100")
        #expect(stringResult.metadata.requestID == "req-1")
        #expect(stringResult.metadata.requestedModelID == Self.modelID)
        #expect(stringResult.metadata.returnedModelID == "openai/gpt-5.5")
        #expect(stringResult.metadata.providerName == "OpenAI")
        #expect(stringResult.metadata.promptTokens == 11)
        #expect(stringResult.metadata.completionTokens == 22)
        #expect(stringResult.metadata.reasoningTokens == 3)
        #expect(stringResult.metadata.totalTokens == 33)
        #expect(stringResult.metadata.costUSD == 0.00012)
        #expect(stringResult.metadata.serviceTier == "standard")
        #expect(partsResult.result.sql == "SELECT id FROM public.users LIMIT 100")
    }

    @Test func malformedHTTP200EnvelopeIsStructuredResponseFailure() throws {
        let parser = OpenRouterResponseParser()

        do {
            _ = try parser.parse(
                data: Data("not json".utf8),
                response: response(url: Self.chatEndpoint, status: 200),
                requestedModelID: Self.modelID,
                mode: .strictJSONSchema,
                requestCount: 1,
                retryCount: 0
            )
            Issue.record("expected malformed envelope failure")
        } catch let failure as OpenRouterFailure {
            #expect(failure.category == .malformedStructuredResponse)
            #expect(failure.diagnostic.httpStatus == 200)
            #expect(failure.diagnostic.requestedModelID == Self.modelID)
        }
    }

    @Test func parserAcceptsFencedJSONOnlyInPromptMode() throws {
        let parser = OpenRouterResponseParser()
        let fenced = "```json\n\(goodContent)\n```"
        let proseWrapped = "Here is the query:\n\(fenced)\nDone."
        let promptResult = try parser.parse(
            data: chatResponse(content: fenced),
            response: response(url: Self.chatEndpoint, status: 200),
            requestedModelID: Self.modelID,
            mode: .promptOnlyJSON,
            requestCount: 1,
            retryCount: 0
        )
        #expect(promptResult.result.sql == "SELECT id FROM public.users LIMIT 100")
        let proseResult = try parser.parse(
            data: chatResponse(content: proseWrapped),
            response: response(url: Self.chatEndpoint, status: 200),
            requestedModelID: Self.modelID,
            mode: .promptOnlyJSON,
            requestCount: 1,
            retryCount: 0
        )
        #expect(proseResult.result.sql == "SELECT id FROM public.users LIMIT 100")

        do {
            _ = try parser.parse(
                data: chatResponse(content: fenced),
                response: response(url: Self.chatEndpoint, status: 200),
                requestedModelID: Self.modelID,
                mode: .strictJSONSchema,
                requestCount: 1,
                retryCount: 0
            )
            Issue.record("expected strict JSON parse failure")
        } catch let failure as OpenRouterFailure {
            #expect(failure.category == .malformedStructuredResponse)
        }
    }

    @Test func http200ErrorEnvelopeUsesBodyCodeForCategory() throws {
        let parser = OpenRouterResponseParser()

        do {
            _ = try parser.parse(
                data: topLevelErrorResponse(
                    code: 429,
                    message: "Rate limit exceeded"
                ),
                response: response(url: Self.chatEndpoint, status: 200),
                requestedModelID: Self.modelID,
                mode: .strictJSONSchema,
                requestCount: 2,
                retryCount: 1
            )
            Issue.record("expected rate limit failure")
        } catch let failure as OpenRouterFailure {
            #expect(failure.category == .rateLimited)
            #expect(failure.diagnostic.httpStatus == 429)
            #expect(failure.diagnostic.attemptCount == 2)
        }
    }

    @Test func parserClassifiesErrorAndFinishFormsBeforeContentParsing() throws {
        let parser = OpenRouterResponseParser()

        try expectFailure(.paymentRequired) {
            try parser.parse(
                data: topLevelErrorResponse(errorType: "insufficient_credits", providerCode: "credits"),
                response: response(url: Self.chatEndpoint, status: 200),
                requestedModelID: Self.modelID,
                mode: .strictJSONSchema,
                requestCount: 1,
                retryCount: 0
            )
        }
        try expectFailure(.providerUnavailable) {
            try parser.parse(
                data: chatResponse(content: nil, finishReason: "error"),
                response: response(url: Self.chatEndpoint, status: 200),
                requestedModelID: Self.modelID,
                mode: .strictJSONSchema,
                requestCount: 1,
                retryCount: 0
            )
        }
        try expectFailure(.maxTokensExceeded) {
            try parser.parse(
                data: chatResponse(content: goodContent, finishReason: "length"),
                response: response(url: Self.chatEndpoint, status: 200),
                requestedModelID: Self.modelID,
                mode: .strictJSONSchema,
                requestCount: 1,
                retryCount: 0
            )
        }
        try expectFailure(.contentPolicy) {
            try parser.parse(
                data: chatResponse(content: goodContent, finishReason: "content_filter"),
                response: response(url: Self.chatEndpoint, status: 200),
                requestedModelID: Self.modelID,
                mode: .strictJSONSchema,
                requestCount: 1,
                retryCount: 0
            )
        }
        try expectFailure(.refusal) {
            try parser.parse(
                data: chatResponse(content: goodContent, refusal: "No."),
                response: response(url: Self.chatEndpoint, status: 200),
                requestedModelID: Self.modelID,
                mode: .strictJSONSchema,
                requestCount: 1,
                retryCount: 0
            )
        }
        try expectFailure(.noContent) {
            try parser.parse(
                data: chatResponse(content: ""),
                response: response(url: Self.chatEndpoint, status: 200),
                requestedModelID: Self.modelID,
                mode: .strictJSONSchema,
                requestCount: 1,
                retryCount: 0
            )
        }
    }

    @Test func choiceLevelErrorInsideHTTP200PreservesProviderCode() throws {
        let parser = OpenRouterResponseParser()
        do {
            _ = try parser.parse(
                data: chatResponse(
                    content: nil,
                    choiceError: [
                        "message": "provider failed",
                        "metadata": ["error_type": "provider_unavailable", "provider_code": "overloaded"],
                    ]
                ),
                response: response(url: Self.chatEndpoint, status: 200),
                requestedModelID: Self.modelID,
                mode: .strictJSONSchema,
                requestCount: 1,
                retryCount: 0
            )
            Issue.record("expected provider error")
        } catch let failure as OpenRouterFailure {
            #expect(failure.category == .providerUnavailable)
            #expect(failure.diagnostic.providerCode == "overloaded")
        }

        try expectFailure(.providerOverloaded) {
            try parser.parse(
                data: chatResponse(
                    content: nil,
                    choiceError: [
                        "message":
                            "The system is currently experiencing high demand and cannot process your request during peak load.",
                    ]
                ),
                response: response(url: Self.chatEndpoint, status: 200),
                requestedModelID: Self.modelID,
                mode: .strictJSONSchema,
                requestCount: 1,
                retryCount: 0
            )
        }
    }

    @Test func everyTypedFailureCategoryIsReachable() {
        let cases: [(String?, Int?, String?, OpenRouterFailure.Category)] = [
            ("invalid_api_key", 400, nil, .authentication),
            ("insufficient_credits", 400, nil, .paymentRequired),
            ("provider_limit_exceeded", 429, nil, .providerLimit),
            ("permission_denied", 403, nil, .permissionDenied),
            ("guardrail_blocked", 403, nil, .guardrailBlocked),
            ("model_not_found", 404, nil, .modelNotFound),
            ("invalid_request", 400, nil, .invalidRequest),
            ("unsupported_parameter", 400, nil, .unsupportedFeature),
            ("context_length_exceeded", 400, nil, .contextWindow),
            ("token_limit_exceeded", 400, nil, .maxTokensExceeded),
            ("max_tokens_exceeded", 400, nil, .maxTokensExceeded),
            ("rate_limit_exceeded", 429, nil, .rateLimited),
            ("provider_overloaded", 503, nil, .providerOverloaded),
            ("provider_unavailable", 502, nil, .providerUnavailable),
            (
                nil,
                200,
                "High demand during peak load; consider Provisioned Throughput.",
                .providerOverloaded
            ),
            ("timeout", 408, nil, .timeout),
            ("content_policy_violation", 400, nil, .contentPolicy),
            ("refusal", 400, nil, .refusal),
            (nil, 204, nil, .serverFailure),
            (nil, 413, "context length exceeded", .contextWindow),
            (nil, 413, nil, .invalidRequest),
            (nil, 422, "token limit exceeded", .contextWindow),
            (nil, 422, nil, .invalidRequest),
            (nil, 500, nil, .serverFailure),
            (nil, nil, nil, .serverFailure),
        ]
        for (type, status, message, category) in cases {
            #expect(
                OpenRouterFailure.category(errorType: type, httpStatus: status, message: message)
                    == category
            )
        }
        #expect(
            OpenRouterFailure.category(
                errorType: nil,
                providerCode: "provider_limit",
                httpStatus: 400,
                message: nil
            ) == .providerLimit
        )
        #expect(
            OpenRouterFailure.category(
                errorType: "rate_limit_exceeded",
                providerCode: "provider_limit",
                httpStatus: 429,
                message: nil
            ) == .providerLimit
        )
        #expect(
            OpenRouterFailure.category(
                errorType: "rate_limit_exceeded",
                providerCode: "credits",
                httpStatus: 429,
                message: nil
            ) == .paymentRequired
        )

        #expect(
            OpenRouterFailure(category: .noContent, message: "empty").category == .noContent
        )
        #expect(
            OpenRouterFailure(category: .malformedStructuredResponse, message: "bad").category
                == .malformedStructuredResponse
        )
        #expect(
            OpenRouterFailure(category: .networkTransport, message: "offline").category
                == .networkTransport
        )
    }

    @Test func retryAfterSecondsHTTPDateAndCapAreHandled() {
        let policy = OpenRouterRetryPolicy()
        let seconds = policy.retryAfter(
            from: response(url: Self.chatEndpoint, status: 429, headers: ["Retry-After": "3"])
        )
        let date = Date(timeIntervalSinceNow: 2)
        let httpDate = Self.httpDateFormatter.string(from: date)
        let dateDelay = policy.retryAfter(
            from: response(url: Self.chatEndpoint, status: 429, headers: ["Retry-After": httpDate])
        )
        let capped = policy.retryDelay(
            for: OpenRouterFailure(
                category: .rateLimited,
                message: "slow down",
                retryAfterSeconds: 30
            ),
            attempt: 1,
            noContentRetries: 0
        )

        #expect(seconds == 3)
        #expect((dateDelay ?? 0) > 0)
        #expect(capped == nil)
    }

    @Test func retryPolicyHonorsMaximumHTTPAttempts() {
        let policy = OpenRouterRetryPolicy(maxAttempts: 1)
        let failure = OpenRouterFailure(
            category: .rateLimited,
            message: "Retry later.",
            httpStatus: 429
        )

        #expect(policy.retryDelay(for: failure, attempt: 1, noContentRetries: 0) == nil)
    }

    @Test func retriesTransientFailuresAndCountsEveryAttempt() async throws {
        let transport = StubTransport([
            .success((catalogResponse(), response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200))),
            .success((errorResponse(errorType: "provider_unavailable"), response(url: Self.chatEndpoint, status: 503, headers: ["Retry-After": "0"]))),
            .success((errorResponse(errorType: "provider_unavailable"), response(url: Self.chatEndpoint, status: 503, headers: ["Retry-After": "0"]))),
            .success((chatResponse(content: goodContent), response(url: Self.chatEndpoint, status: 200))),
        ])
        let result = try await makeGenerator(transport: transport).generateSQL(
            question: "show users",
            schema: makeSchema(),
            config: SQLGenerationConfig()
        )

        #expect(result.generationCallCount == 3)
        #expect(result.backendMetadata?.requestCount == 3)
        #expect(result.backendMetadata?.retryCount == 2)
        #expect(transport.requests.filter { $0.url?.path == "/api/v1/chat/completions" }.count == 3)
    }

    @Test func retriesServerFailuresAndCountsAttempts() async throws {
        let transport = StubTransport([
            .success((catalogResponse(), response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200))),
            .success((errorResponse(errorType: "server"), response(url: Self.chatEndpoint, status: 500, headers: ["Retry-After": "0"]))),
            .success((chatResponse(content: goodContent), response(url: Self.chatEndpoint, status: 200))),
        ])
        let result = try await makeGenerator(transport: transport).generateSQL(
            question: "show users",
            schema: makeSchema(),
            config: SQLGenerationConfig()
        )

        #expect(result.generationCallCount == 2)
        #expect(result.backendMetadata?.requestCount == 2)
        #expect(result.backendMetadata?.retryCount == 1)
        #expect(transport.requests.filter { $0.url?.path == "/api/v1/chat/completions" }.count == 2)
    }

    @Test func retryCapStopsAfterThreeHTTPAttempts() async throws {
        let transport = StubTransport([
            .success((catalogResponse(), response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200))),
            .success((errorResponse(errorType: "provider_unavailable"), response(url: Self.chatEndpoint, status: 503, headers: ["Retry-After": "0"]))),
            .success((errorResponse(errorType: "provider_unavailable"), response(url: Self.chatEndpoint, status: 503, headers: ["Retry-After": "0"]))),
            .success((errorResponse(errorType: "provider_unavailable"), response(url: Self.chatEndpoint, status: 503, headers: ["Retry-After": "0"]))),
        ])

        do {
            _ = try await makeGenerator(transport: transport).generateSQL(
                question: "show users",
                schema: makeSchema(),
                config: SQLGenerationConfig()
            )
            Issue.record("expected provider failure")
        } catch let failure as OpenRouterFailure {
            #expect(failure.category == .providerUnavailable)
            #expect(failure.diagnostic.attemptCount == 3)
        }
        #expect(transport.requests.filter { $0.url?.path == "/api/v1/chat/completions" }.count == 3)
    }

    @Test func cancellationDuringRequestAndBackoffIsImmediate() async throws {
        let requestTransport = CancellationAwareTransport()
        let requestTask = Task {
            try await makeGenerator(transport: requestTransport).generateSQL(
                question: "show users",
                schema: makeSchema(),
                config: SQLGenerationConfig()
            )
        }
        while requestTransport.requests.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        requestTask.cancel()
        await expectCancellation(requestTask)

        let backoffTransport = StubTransport([
            .success((catalogResponse(), response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200))),
            .success((errorResponse(errorType: "provider_unavailable"), response(url: Self.chatEndpoint, status: 503, headers: ["Retry-After": "10"]))),
        ])
        let backoffTask = Task {
            try await makeGenerator(transport: backoffTransport).generateSQL(
                question: "show users",
                schema: makeSchema(),
                config: SQLGenerationConfig()
            )
        }
        while backoffTransport.requests.count < 2 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        backoffTask.cancel()
        await expectCancellation(backoffTask)
    }

    @Test func sqlGenerationResultDecodesLegacyJSONWithoutBackendMetadata() throws {
        let legacy = Data(
            """
            {"sql":"SELECT 1","explanation":"x","assumptions":[],"referencedTables":[],"confidence":0.5,"riskLevel":"low","needsClarification":false}
            """.utf8
        )
        let decoded = try JSONDecoder().decode(SQLGenerationResult.self, from: legacy)
        #expect(decoded.backendMetadata == nil)
    }

    @Test func testModelPayloadContainsNoDatabaseContextOrSchema() throws {
        var capabilities = OpenRouterModelCapabilities.conservative()
        capabilities.supportsStructuredOutputs = true
        let request = try OpenRouterRequestBuilder(endpoint: Self.chatEndpoint).buildTinyJSONTest(
            apiKey: "test-key",
            model: Self.modelID,
            capabilities: capabilities
        ).request
        let body = try jsonBody(request)
        let messages = try #require(body["messages"] as? [[String: String]])
        let combined = messages.compactMap { $0["content"] }.joined(separator: "\n")

        #expect(combined.contains("SELECT 1"))
        #expect(combined.contains("\"sql\""))
        #expect(!combined.contains("TABLE"))
        #expect(!combined.contains("Database context"))
        #expect(!combined.contains("SQL history"))
        #expect(!combined.contains("public.users"))
    }

    @Test func connectivityMarksSingleLookupModelAvailableAfterSuccessfulTest() async throws {
        let model = "custom/model"
        let transport = StubTransport([
            .success((catalogResponse(id: "openai/other"), response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200))),
            .success((catalogResponse(id: "openai/other"), response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200))),
            .success((singleModelResponse(id: model), response(url: Self.apiBase.appendingPathComponent("model/custom/model"), status: 200))),
            .success((chatResponse(content: goodContent), response(url: Self.chatEndpoint, status: 200))),
        ])
        let service = catalogService(transport: transport)

        let result = await OpenRouterConnectivityCheck(
            apiKey: "test-key",
            model: model,
            catalogService: service,
            transport: transport,
            requestBuilder: OpenRouterRequestBuilder(endpoint: Self.chatEndpoint)
        ).run()

        #expect(result.error == nil)
        #expect(result.selectedModelAvailable)
        #expect(result.capabilities.supportsMaxTokens)
        #expect(
            transport.requests.map { $0.url?.path } == [
                "/api/v1/models/user",
                "/api/v1/models/user",
                "/api/v1/model/custom/model",
                "/api/v1/chat/completions",
            ]
        )
    }

    @Test func catalogLookupCanExhaustHTTPBudgetBeforeChatRequest() async throws {
        let transport = StubTransport([
            .success((catalogResponse(), response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200)))
        ])
        let generator = makeGenerator(
            transport: transport,
            retryPolicy: OpenRouterRetryPolicy(maxAttempts: 1),
            countCapabilityLookupHTTPAttempts: true
        )

        do {
            _ = try await generator.generateSQL(
                question: "List users",
                schema: makeSchema(),
                context: SQLGenerationContext(),
                config: SQLGenerationConfig()
            )
            Issue.record("Expected HTTP-attempt budget exhaustion.")
        } catch let failure as OpenRouterHTTPAttemptBudgetExhausted {
            #expect(failure.backendMetadata?.requestCount == 1)
            #expect(transport.requests.map { $0.url?.path } == ["/api/v1/models/user"])
        }
    }

    @Test func catalogLookupCountsTowardLegacyFailureAttempts() async throws {
        let transport = StubTransport([
            .success((catalogResponse(), response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200))),
            .success((errorResponse(errorType: "rate_limit_exceeded"), response(url: Self.chatEndpoint, status: 429))),
        ])
        let generator = makeGenerator(
            transport: transport,
            retryPolicy: OpenRouterRetryPolicy(maxAttempts: 2),
            countCapabilityLookupHTTPAttempts: true
        )

        do {
            _ = try await generator.generateSQL(
                question: "List users",
                schema: makeSchema(),
                context: SQLGenerationContext(),
                config: SQLGenerationConfig()
            )
            Issue.record("Expected OpenRouter failure.")
        } catch let failure as OpenRouterFailure {
            #expect(failure.category == .rateLimited)
            #expect(failure.diagnostic.attemptCount == 2)
            #expect(
                transport.requests.map { $0.url?.path } == [
                    "/api/v1/models/user",
                    "/api/v1/chat/completions",
                ]
            )
        }
    }

    private func makeGenerator(
        transport: StubTransport,
        model: String = Self.modelID,
        retryPolicy: OpenRouterRetryPolicy = OpenRouterRetryPolicy(),
        countCapabilityLookupHTTPAttempts: Bool = false
    ) -> OpenRouterSQLGenerator {
        OpenRouterSQLGenerator(
            apiKey: "test-key",
            model: model,
            transport: transport,
            catalogService: catalogService(transport: transport),
            requestBuilder: OpenRouterRequestBuilder(endpoint: Self.chatEndpoint),
            retryPolicy: retryPolicy,
            countCapabilityLookupHTTPAttempts: countCapabilityLookupHTTPAttempts
        )
    }

    private func makeGenerator(transport: CancellationAwareTransport) -> OpenRouterSQLGenerator {
        OpenRouterSQLGenerator(
            apiKey: "test-key",
            model: Self.modelID,
            transport: transport,
            catalogService: catalogService(transport: transport),
            requestBuilder: OpenRouterRequestBuilder(endpoint: Self.chatEndpoint)
        )
    }

    private func catalogService(
        transport: DelayedTransport,
        cacheURL: URL? = nil,
        ttl: TimeInterval = 60
    ) -> OpenRouterModelCatalogService {
        catalogService(transport: transport as any HTTPTransport, cacheURL: cacheURL, ttl: ttl)
    }

    private func catalogService(
        transport: any HTTPTransport,
        cacheURL: URL? = nil,
        ttl: TimeInterval = 60
    ) -> OpenRouterModelCatalogService {
        OpenRouterModelCatalogService(
            transport: transport,
            baseURL: Self.apiBase,
            cacheURL: cacheURL ?? temporaryCacheURL(),
            ttl: ttl
        )
    }

    private func makeSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "users",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "users",
                            name: "id",
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 1
                        )
                    ]
                )
            ]
        )
    }

    private func catalogResponse(
        id: String = modelID,
        canonicalID: String? = nil,
        parameters: [String] = [
            "response_format", "structured_outputs", "tools", "tool_choice", "temperature", "seed",
            "max_completion_tokens", "max_tokens",
        ]
    ) -> Data {
        jsonData([
            "data": [
                modelObject(id: id, canonicalID: canonicalID, parameters: parameters),
            ],
        ])
    }

    private func singleModelResponse(id: String) -> Data {
        jsonData(["data": modelObject(id: id, parameters: ["max_tokens"])])
    }

    private func modelObject(id: String, canonicalID: String? = nil, parameters: [String]) -> [String: Any] {
        [
            "id": id,
            "canonical_slug": canonicalID ?? id,
            "name": id == Self.modelID ? "GPT-5.5" : id,
            "context_length": 128_000,
            "top_provider": [
                "context_length": 128_000,
                "max_completion_tokens": 4096,
            ],
            "supported_parameters": parameters,
            "pricing": [
                "prompt": "0.000001",
                "completion": "0.000002",
                "request": "0",
                "image": "0",
            ],
            "expiration_date": "2027-01-01",
        ]
    }

    private func chatResponse(
        content: Any?,
        finishReason: String = "stop",
        refusal: String? = nil,
        choiceError: [String: Any]? = nil
    ) -> Data {
        var message: [String: Any] = ["role": "assistant"]
        if let content {
            message["content"] = content
        }
        if let refusal {
            message["refusal"] = refusal
        }
        var choice: [String: Any] = [
            "index": 0,
            "finish_reason": finishReason,
            "native_finish_reason": finishReason,
            "message": message,
        ]
        if let choiceError {
            choice["error"] = choiceError
        }
        return jsonData([
            "id": "cmpl-1",
            "model": "openai/gpt-5.5",
            "provider": "OpenAI",
            "service_tier": "standard",
            "choices": [choice],
            "usage": [
                "prompt_tokens": 11,
                "completion_tokens": 22,
                "total_tokens": 33,
                "completion_tokens_details": ["reasoning_tokens": 3],
                "cost": 0.00012,
            ],
        ])
    }

    private func topLevelErrorResponse(
        code: Int? = nil,
        message: String = "provider error",
        errorType: String? = nil,
        providerCode: String? = nil
    ) -> Data {
        var metadata: [String: Any] = [:]
        if let errorType {
            metadata["error_type"] = errorType
        }
        if let providerCode {
            metadata["provider_code"] = providerCode
        }
        var error: [String: Any] = [
            "message": message,
        ]
        if let code {
            error["code"] = code
        }
        if !metadata.isEmpty {
            error["metadata"] = metadata
        }
        return jsonData([
            "id": "cmpl-1",
            "model": "openai/gpt-5.5",
            "provider": "OpenAI",
            "error": error,
        ])
    }

    private func errorResponse(errorType: String, message: String = "OpenRouter error") -> Data {
        jsonData([
            "error": [
                "message": message,
                "metadata": ["error_type": errorType, "provider_code": "provider-code"],
            ],
        ])
    }

    private func response(
        url: URL,
        status: Int,
        headers: [String: String]? = nil
    ) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    private func jsonData(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let bodyData = try #require(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: bodyData)
        return try #require(object as? [String: Any])
    }

    private func temporaryCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("openrouter-cache.json")
    }

    private func expectFailure(
        _ category: OpenRouterFailure.Category,
        operation: () throws -> OpenRouterResponseParser.ParsedResult
    ) throws {
        do {
            _ = try operation()
            Issue.record("expected \(category)")
        } catch let failure as OpenRouterFailure {
            #expect(failure.category == category)
        }
    }

    private func expectCancellation<Value>(_ task: Task<Value, Error>) async {
        do {
            _ = try await task.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            return
        } catch {
            Issue.record("expected CancellationError, got \(error)")
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
