import Foundation
import Testing

@testable import WidenKit

@Suite("OpenRouter reliability")
struct CloudSQLGeneratorTests {
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

    private final class UsageEventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [SQLGenerationUsageEvent] = []

        var events: [SQLGenerationUsageEvent] {
            lock.withLock { recorded }
        }

        func record(_ event: SQLGenerationUsageEvent) {
            lock.withLock { recorded.append(event) }
        }
    }

    enum ParticleRetry: Sendable {
        case never
        case retryable
        case once
    }

    /// One row of Particle's error table: a typed code or type at the HTTP
    /// status Particle sends it with.
    struct ParticleErrorRow: Sendable, CustomTestStringConvertible {
        var code: String?
        var type: String?
        var status: Int
        var category: CloudRequestFailure.Category
        var retry: ParticleRetry

        var testDescription: String {
            "\(code ?? type ?? "?") → \(category.rawValue)"
        }
    }

    private static let particleErrorRows: [ParticleErrorRow] = [
        .init(code: "invalid_bearer_credential", status: 401, category: .authentication, retry: .never),
        .init(code: "insufficient_credits", status: 402, category: .paymentRequired, retry: .never),
        .init(code: "insufficient_scope", status: 403, category: .permissionDenied, retry: .never),
        .init(code: "model_not_found", status: 404, category: .modelNotFound, retry: .never),
        .init(code: "request_too_large", status: 413, category: .contextWindow, retry: .never),
        .init(code: "tokenization_body_too_large", status: 413, category: .contextWindow, retry: .never),
        .init(code: "context_length_exceeded", status: 400, category: .contextWindow, retry: .never),
        .init(code: "unsupported_parameter", status: 400, category: .unsupportedFeature, retry: .never),
        .init(code: "invalid_json", status: 400, category: .invalidRequest, retry: .never),
        .init(code: "invalid_value", status: 400, category: .invalidRequest, retry: .never),
        .init(code: "fleet_capacity_exhausted", status: 429, category: .rateLimited, retry: .retryable),
        .init(code: "internal_error", status: 500, category: .serverFailure, retry: .retryable),
        .init(code: "invalid_upstream_response", status: 502, category: .providerUnavailable, retry: .retryable),
        .init(code: "invalid_model_output", status: 502, category: .malformedStructuredResponse, retry: .once),
        .init(code: "model_unavailable", status: 503, category: .providerUnavailable, retry: .retryable),
        .init(code: "billing_unavailable", status: 503, category: .providerUnavailable, retry: .retryable),
        .init(code: "upstream_response_deadline_exceeded", status: 504, category: .timeout, retry: .retryable),
        .init(type: "authentication_error", status: 401, category: .authentication, retry: .never),
        .init(type: "insufficient_credits_error", status: 402, category: .paymentRequired, retry: .never),
        .init(type: "authorization_error", status: 403, category: .permissionDenied, retry: .never),
        .init(type: "invalid_request_error", status: 400, category: .invalidRequest, retry: .never),
        .init(type: "rate_limit_error", status: 429, category: .rateLimited, retry: .retryable),
    ]

    private static let chatEndpoint = URL(string: "https://openrouter.test/api/v1/chat/completions")!
    private static let particleChatEndpoint = CloudModelProfile.particleTest.chatCompletionsURL
    private static let particleModelID = CloudModelProfile.particleTest.requestedModelID
    private static let apiBase = URL(string: "https://openrouter.test/api/v1")!
    private static let modelID = "openai/gpt-5.5"
    /// The OpenRouter profile's completion cap, pinned so the eval-only
    /// profile keeps sending the token budget the app always sent.
    private static let openRouterCompletionTokenBudget = 2_048

    /// Profiles that pin the returned model, for checks that must hold for
    /// Particle-1 and for the OpenRouter eval profile alike.
    /// Profiles whose returned model any fixture satisfies, for chat and
    /// retry behavior both providers must share.
    private static let chatProfiles: [CloudModelProfile] = [.particleTest, .openRouterTest]

    private static let pinnedProfiles: [CloudModelProfile] = [
        .particleTest,
        .openRouterTest.pinningReturnedModel("openai/gpt-5.5-20260423"),
    ]

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
        } catch let failure as CloudRequestFailure {
            #expect(failure.category == .authentication)
        }
        #expect(authFailureTransport.requests.count == 1)
    }

    @Test func settingsMetadataLookupSurfacesAuthenticationFailure() async throws {
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
            _ = try await expiredService.metadataSurfacingErrors(
                apiKey: "secret-key",
                modelID: Self.modelID
            )
            Issue.record("expected authentication failure")
        } catch let failure as CloudRequestFailure {
            #expect(failure.category == .authentication)
        }
    }

    @Test func settingsMetadataLookupServesStaleCacheForTransientFailures() async throws {
        let cacheURL = temporaryCacheURL()
        let primingTransport = StubTransport([
            .success((catalogResponse(id: Self.modelID), response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200)))
        ])
        let primingService = catalogService(transport: primingTransport, cacheURL: cacheURL, ttl: 60)
        _ = try await primingService.availableModels(apiKey: "secret-key")

        let flakyTransport = StubTransport([.failure(URLError(.networkConnectionLost))])
        let expiredService = catalogService(transport: flakyTransport, cacheURL: cacheURL, ttl: -1)

        let metadata = try await expiredService.metadataSurfacingErrors(
            apiKey: "secret-key",
            modelID: Self.modelID
        )
        #expect(metadata?.capabilitySource == .staleCache)
    }

    @Test func keyLimitExceededClassifiesAsProviderBudget() {
        let category = CloudRequestFailure.category(
            errorType: nil,
            providerCode: nil,
            httpStatus: 403,
            message: "Key limit exceeded (total limit). Manage it using https://openrouter.ai/keys",
            profile: .openRouterTest
        )
        #expect(category == .providerLimit)
        #expect(category.isProviderBudgetUnavailable)
    }

    @Test func envelopedKeyLimitErrorsClassifyAsProviderBudget() {
        #expect(
            CloudRequestFailure.category(
                errorType: nil,
                providerCode: nil,
                httpStatus: 200,
                message: "Insufficient credits remaining for this key",
                profile: .openRouterTest
            ) == .providerLimit
        )
    }

    @Test func parameterRoutingFailureExplainsPrivateRoutingRequirements() throws {
        let failure = CloudSQLResponseParser.failure(
            from: errorResponse(
                errorType: "routing",
                message: "No endpoints found that support the requested parameters."
            ),
            response: response(url: Self.chatEndpoint, status: 404),
            requestedModelID: Self.modelID,
            attemptCount: 1,
            profile: .openRouterTest
        )
        #expect(failure.message.contains("private-routing requirements"))
    }

    @Test func keyLimitMessageDoesNotReclassifyAuthenticationOrServerFailures() {
        #expect(
            CloudRequestFailure.category(
                errorType: nil,
                providerCode: nil,
                httpStatus: 401,
                message: "Key limit exceeded for a disabled key",
                profile: .openRouterTest
            ) == .authentication
        )
        #expect(
            CloudRequestFailure.category(
                errorType: nil,
                providerCode: nil,
                httpStatus: 500,
                message: "Upstream provider hit its credit limit",
                profile: .openRouterTest
            ) == .serverFailure
        )
    }

    @Test func genericNoEndpointsFailureIsNotAttributedToPrivateRouting() throws {
        let failure = CloudSQLResponseParser.failure(
            from: errorResponse(
                errorType: "routing",
                message: "No endpoints found for openai/gpt-5.5."
            ),
            response: response(url: Self.chatEndpoint, status: 404),
            requestedModelID: Self.modelID,
            attemptCount: 1,
            profile: .openRouterTest
        )
        #expect(failure.category == .modelNotFound)
        #expect(!failure.message.contains("private-routing requirements"))
    }

    @Test func routingPolicyFailureExplainsPrivateRoutingRequirements() throws {
        let failure = CloudSQLResponseParser.failure(
            from: errorResponse(
                errorType: "routing",
                message: "No endpoints found matching your data policy (Zero data retention)."
            ),
            response: response(url: Self.chatEndpoint, status: 404),
            requestedModelID: Self.modelID,
            attemptCount: 1,
            profile: .openRouterTest
        )
        #expect(failure.category == .modelNotFound)
        #expect(failure.message.contains("private-routing requirements"))
        #expect(failure.message.contains("data policy"))
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

    @Test func cancelledSettingsMetadataLookupRethrowsCancellationInsteadOfServingStaleCache()
        async throws
    {
        let cacheURL = temporaryCacheURL()
        let primingTransport = StubTransport([
            .success((
                catalogResponse(),
                response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200)
            ))
        ])
        let primingService = catalogService(transport: primingTransport, cacheURL: cacheURL)
        _ = try await primingService.availableModels(apiKey: "secret-key")

        let transport = CancellationAwareTransport()
        let service = catalogService(transport: transport, cacheURL: cacheURL)
        let lookup = Task {
            try await service.metadataSurfacingErrors(
                apiKey: "secret-key",
                modelID: Self.modelID,
                forceRefresh: true
            )
        }
        while transport.requests.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        lookup.cancel()

        await expectCancellation(lookup)
    }

    @Test func cancelledCatalogRefreshReplacesStaleStatusAndStopsLoading() {
        let metadata = OpenRouterModelMetadata(
            requestedID: Self.modelID,
            id: Self.modelID,
            canonicalModelID: "openai/gpt-5.5-20260423",
            displayName: "GPT-5.5",
            contextLength: 128_000,
            maximumCompletionTokens: 4_096,
            supportedParameters: [],
            pricing: nil,
            expiration: nil,
            isAvailableToAPIKey: true,
            capabilitySource: .authenticatedCatalog,
            fetchedAt: Date(timeIntervalSince1970: 1)
        )
        var presentation = OpenRouterCatalogRefreshPresentation(
            modelMetadata: metadata,
            message: "Authenticated model metadata loaded.",
            messageIsWarning: false,
            isLoading: true
        )

        presentation.finish(with: .cancelled)

        #expect(presentation.modelMetadata == metadata)
        #expect(presentation.message == "OpenRouter model metadata refresh was cancelled.")
        #expect(presentation.messageIsWarning)
        #expect(!presentation.isLoading)
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
        let built = try ChatCompletionRequestBuilder(profile: .openRouterTest).build(
            apiKey: "test-key",
            instructions: "instructions",
            prompt: "prompt",
            capabilities: .conservative()
        )
        let body = try jsonBody(built.request)

        #expect(built.mode == .promptOnlyJSON)
        #expect(body["response_format"] == nil)
        #expect(body["temperature"] == nil)
        #expect(body["max_tokens"] as? Int == Self.openRouterCompletionTokenBudget)
        #expect(body["max_completion_tokens"] == nil)
        try expectPrivateRouting(in: built.request)
        #expect(built.request.value(forHTTPHeaderField: "X-OpenRouter-Metadata") == "enabled")
    }

    @Test func privateRoutingPreferencesSetExactlyTheRequiredProviderBlock() throws {
        var body: [String: Any] = ["model": "openai/gpt-5.5"]
        OpenRouterProviderPreferences.apply(to: &body)
        try OpenRouterTestSupport.expectPrivateRouting(inBody: body)
    }

    @Test func requestBuilderUsesStrictModeOnlyWhenAdvertised() throws {
        var capabilities = CloudModelCapabilities.conservative()
        capabilities.supportsResponseFormat = true
        capabilities.supportsStructuredOutputs = true
        capabilities.supportsTemperature = true
        capabilities.supportsMaxTokens = true
        capabilities.supportsMaxCompletionTokens = true
        capabilities.maximumCompletionTokens = 32

        let built = try ChatCompletionRequestBuilder(profile: .openRouterTest).build(
            apiKey: "test-key",
            instructions: "instructions",
            prompt: "prompt",
            capabilities: capabilities
        )
        let body = try jsonBody(built.request)
        let provider = body["provider"] as? [String: Any]

        #expect(built.mode == .strictJSONSchema)
        #expect(body["response_format"] != nil)
        #expect(provider?["require_parameters"] as? Bool == true)
        #expect(provider?["zdr"] as? Bool == true)
        #expect(provider?["data_collection"] as? String == "deny")
        #expect(body["temperature"] as? Int == 0)
        #expect(body["max_completion_tokens"] as? Int == 32)
        #expect(body["max_tokens"] == nil)
    }

    @Test func strictSchemaOmitsUnadvertisedTokenCaps() throws {
        var capabilities = CloudModelCapabilities.conservative()
        capabilities.supportsStructuredOutputs = true

        let built = try ChatCompletionRequestBuilder(profile: .openRouterTest).build(
            apiKey: "test-key",
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
        var capabilities = CloudModelCapabilities.conservative()
        capabilities.supportsResponseFormat = true
        capabilities.supportsTemperature = true

        let built = try ChatCompletionRequestBuilder(profile: .openRouterTest).build(
            apiKey: "test-key",
            instructions: "instructions",
            prompt: "prompt",
            capabilities: capabilities
        )
        let body = try jsonBody(built.request)

        #expect(built.mode == .promptOnlyJSON)
        #expect(body["response_format"] == nil)
        try expectPrivateRouting(in: built.request)
        #expect(body["temperature"] as? Int == 0)
        #expect(body["max_tokens"] as? Int == Self.openRouterCompletionTokenBudget)
    }

    @Test func maxTokensFallbackIsUsedOnlyWhenAdvertised() throws {
        var capabilities = CloudModelCapabilities.conservative()
        capabilities.supportsMaxTokens = true
        capabilities.maximumCompletionTokens = 16_000

        let body = try jsonBody(
            ChatCompletionRequestBuilder(profile: .openRouterTest).build(
                apiKey: "test-key",
                instructions: "instructions",
                prompt: "prompt",
                capabilities: capabilities
            ).request
        )

        #expect(body["max_tokens"] as? Int == Self.openRouterCompletionTokenBudget)
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
        } catch let failure as CloudRequestFailure {
            #expect(failure.category == .unsupportedFeature)
        }

        #expect(transport.requests.map { $0.url?.path } == ["/api/v1/models/user", "/api/v1/chat/completions"])
    }

    @Test func parserHandlesStringAndContentParts() throws {
        let parser = CloudSQLResponseParser(profile: .openRouterTest)
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

    @Test func parserRejectsUnexpectedCanonicalModelWhenEnforced() throws {
        let parser = CloudSQLResponseParser(
            profile: .openRouterTest.pinningReturnedModel("openai/gpt-5.5-20260423")
        )
        let returnedModelID = "openai/gpt-5.5-unevaluated"

        do {
            _ = try parser.parse(
                data: chatResponse(content: goodContent, model: returnedModelID),
                response: response(url: Self.chatEndpoint, status: 200),
                requestedModelID: Self.modelID,
                mode: .strictJSONSchema,
                requestCount: 1,
                retryCount: 0
            )
            Issue.record("expected canonical model mismatch")
        } catch let failure as CloudRequestFailure {
            #expect(failure.category == .modelVersionMismatch)
            #expect(failure.pipelineCategory == .backendUnavailable)
            #expect(failure.diagnostic.requestedModelID == Self.modelID)
            #expect(failure.diagnostic.returnedModelID == returnedModelID)
        }
    }

    @Test func parserAcceptsAliasWhenRouterMetadataPinsExpectedCanonicalModel() throws {
        let expectedCanonicalModelID = "openai/gpt-5.5-20260423"
        let parser = CloudSQLResponseParser(
            profile: .openRouterTest.pinningReturnedModel(expectedCanonicalModelID)
        )

        let parsed = try parser.parse(
            data: chatResponse(
                content: goodContent,
                openrouterMetadata: routerMetadata(
                    requestedModelID: Self.modelID,
                    selectedModelIDs: [expectedCanonicalModelID]
                )
            ),
            response: response(url: Self.chatEndpoint, status: 200),
            requestedModelID: Self.modelID,
            mode: .strictJSONSchema,
            requestCount: 1,
            retryCount: 0
        )

        #expect(parsed.metadata.returnedModelID == Self.modelID)
    }

    @Test func parserRejectsAliasWithoutUnambiguousMatchingRouterMetadata() throws {
        let expectedCanonicalModelID = "openai/gpt-5.5-20260423"
        let parser = CloudSQLResponseParser(
            profile: .openRouterTest.pinningReturnedModel(expectedCanonicalModelID)
        )
        let responses = [
            chatResponse(content: goodContent),
            chatResponse(
                content: goodContent,
                openrouterMetadata: routerMetadata(
                    requestedModelID: "openai/gpt-5.5-unevaluated",
                    selectedModelIDs: [expectedCanonicalModelID]
                )
            ),
            chatResponse(
                content: goodContent,
                openrouterMetadata: routerMetadata(
                    requestedModelID: Self.modelID,
                    selectedModelIDs: ["openai/gpt-5.5-unevaluated"]
                )
            ),
            chatResponse(
                content: goodContent,
                openrouterMetadata: routerMetadata(
                    requestedModelID: Self.modelID,
                    selectedModelIDs: [expectedCanonicalModelID, expectedCanonicalModelID]
                )
            ),
            chatResponse(
                content: goodContent,
                model: "openai/gpt-5.5-unevaluated",
                openrouterMetadata: routerMetadata(
                    requestedModelID: Self.modelID,
                    selectedModelIDs: [expectedCanonicalModelID]
                )
            ),
        ]

        for data in responses {
            do {
                _ = try parser.parse(
                    data: data,
                    response: response(url: Self.chatEndpoint, status: 200),
                    requestedModelID: Self.modelID,
                    mode: .strictJSONSchema,
                    requestCount: 1,
                    retryCount: 0
                )
                Issue.record("expected incomplete or conflicting canonical evidence to fail")
            } catch let failure as CloudRequestFailure {
                #expect(failure.category == .modelVersionMismatch)
            }
        }
    }

    @Test func parserRejectsCanonicalModelWhenRouterMetadataConflicts() throws {
        let expectedCanonicalModelID = "openai/gpt-5.5-20260423"
        let parser = CloudSQLResponseParser(
            profile: .openRouterTest.pinningReturnedModel(expectedCanonicalModelID)
        )
        let responses = [
            chatResponse(
                content: goodContent,
                model: expectedCanonicalModelID,
                openrouterMetadata: routerMetadata(
                    requestedModelID: "openai/gpt-5.5-unevaluated",
                    selectedModelIDs: [expectedCanonicalModelID]
                )
            ),
            chatResponse(
                content: goodContent,
                model: expectedCanonicalModelID,
                openrouterMetadata: routerMetadata(
                    requestedModelID: Self.modelID,
                    selectedModelIDs: ["openai/gpt-5.5-unevaluated"]
                )
            ),
            chatResponse(
                content: goodContent,
                model: expectedCanonicalModelID,
                openrouterMetadata: routerMetadata(
                    requestedModelID: Self.modelID,
                    selectedModelIDs: [expectedCanonicalModelID, expectedCanonicalModelID]
                )
            ),
        ]

        for data in responses {
            do {
                _ = try parser.parse(
                    data: data,
                    response: response(url: Self.chatEndpoint, status: 200),
                    requestedModelID: Self.modelID,
                    mode: .strictJSONSchema,
                    requestCount: 1,
                    retryCount: 0
                )
                Issue.record("expected contradictory canonical evidence to fail")
            } catch let failure as CloudRequestFailure {
                #expect(failure.category == .modelVersionMismatch)
            }
        }
    }

    @Test func malformedHTTP200EnvelopeIsStructuredResponseFailure() throws {
        let parser = CloudSQLResponseParser(profile: .particleTest)

        do {
            _ = try parser.parse(
                data: Data("not json".utf8),
                response: response(url: Self.particleChatEndpoint, status: 200),
                requestedModelID: Self.particleModelID,
                mode: .strictJSONSchema,
                requestCount: 1,
                retryCount: 0
            )
            Issue.record("expected malformed envelope failure")
        } catch let failure as CloudRequestFailure {
            #expect(failure.category == .malformedStructuredResponse)
            #expect(failure.diagnostic.httpStatus == 200)
            #expect(failure.diagnostic.requestedModelID == Self.particleModelID)
        }
    }

    @Test func malformedEnvelopeFailurePreservesReportedUsage() throws {
        let parser = CloudSQLResponseParser(profile: .openRouterTest)
        let data = jsonData([
            "choices": "invalid",
            "usage": [
                "prompt_tokens": 4,
                "completion_tokens": 5,
                "total_tokens": 9,
                "completion_tokens_details": ["reasoning_tokens": 2],
                "cost": 0.25,
            ],
        ])

        do {
            _ = try parser.parse(
                data: data,
                response: response(url: Self.chatEndpoint, status: 200),
                requestedModelID: Self.modelID,
                mode: .strictJSONSchema,
                requestCount: 1,
                retryCount: 0
            )
            Issue.record("expected malformed envelope failure")
        } catch let failure as CloudRequestFailure {
            #expect(failure.category == .malformedStructuredResponse)
            #expect(failure.diagnostic.promptTokens == 4)
            #expect(failure.diagnostic.completionTokens == 5)
            #expect(failure.diagnostic.reasoningTokens == 2)
            #expect(failure.diagnostic.totalTokens == 9)
            #expect(failure.diagnostic.costUSD == 0.25)
        }
    }

    @Test func parserAcceptsFencedJSONOnlyInPromptMode() throws {
        let parser = CloudSQLResponseParser(profile: .particleTest)
        let fenced = "```json\n\(goodContent)\n```"
        let proseWrapped = "Here is the query:\n\(fenced)\nDone."
        let promptResult = try parser.parse(
            data: particleChatResponse(content: fenced),
            response: response(url: Self.particleChatEndpoint, status: 200),
            requestedModelID: Self.particleModelID,
            mode: .promptOnlyJSON,
            requestCount: 1,
            retryCount: 0
        )
        #expect(promptResult.result.sql == "SELECT id FROM public.users LIMIT 100")
        let proseResult = try parser.parse(
            data: particleChatResponse(content: proseWrapped),
            response: response(url: Self.particleChatEndpoint, status: 200),
            requestedModelID: Self.particleModelID,
            mode: .promptOnlyJSON,
            requestCount: 1,
            retryCount: 0
        )
        #expect(proseResult.result.sql == "SELECT id FROM public.users LIMIT 100")

        do {
            _ = try parser.parse(
                data: particleChatResponse(content: fenced),
                response: response(url: Self.particleChatEndpoint, status: 200),
                requestedModelID: Self.particleModelID,
                mode: .strictJSONSchema,
                requestCount: 1,
                retryCount: 0
            )
            Issue.record("expected strict JSON parse failure")
        } catch let failure as CloudRequestFailure {
            #expect(failure.category == .malformedStructuredResponse)
        }
    }

    @Test func http200ErrorEnvelopeUsesBodyCodeForCategory() throws {
        let parser = CloudSQLResponseParser(profile: .openRouterTest)

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
        } catch let failure as CloudRequestFailure {
            #expect(failure.category == .rateLimited)
            #expect(failure.diagnostic.httpStatus == 429)
            #expect(failure.diagnostic.attemptCount == 2)
        }
    }

    @Test func parserClassifiesErrorAndFinishFormsBeforeContentParsing() throws {
        let parser = CloudSQLResponseParser(profile: .particleTest)

        try expectFailure(.paymentRequired) {
            try parser.parse(
                data: topLevelErrorResponse(errorType: "insufficient_credits", providerCode: "credits"),
                response: response(url: Self.particleChatEndpoint, status: 200),
                requestedModelID: Self.particleModelID,
                mode: .strictJSONSchema,
                requestCount: 1,
                retryCount: 0
            )
        }
        try expectFailure(.providerUnavailable) {
            try parser.parse(
                data: chatResponse(content: nil, finishReason: "error"),
                response: response(url: Self.particleChatEndpoint, status: 200),
                requestedModelID: Self.particleModelID,
                mode: .strictJSONSchema,
                requestCount: 1,
                retryCount: 0
            )
        }
        try expectFailure(.maxTokensExceeded) {
            try parser.parse(
                data: chatResponse(content: goodContent, finishReason: "length"),
                response: response(url: Self.particleChatEndpoint, status: 200),
                requestedModelID: Self.particleModelID,
                mode: .strictJSONSchema,
                requestCount: 1,
                retryCount: 0
            )
        }
        try expectFailure(.contentPolicy) {
            try parser.parse(
                data: chatResponse(content: goodContent, finishReason: "content_filter"),
                response: response(url: Self.particleChatEndpoint, status: 200),
                requestedModelID: Self.particleModelID,
                mode: .strictJSONSchema,
                requestCount: 1,
                retryCount: 0
            )
        }
        try expectFailure(.refusal) {
            try parser.parse(
                data: chatResponse(content: goodContent, refusal: "No."),
                response: response(url: Self.particleChatEndpoint, status: 200),
                requestedModelID: Self.particleModelID,
                mode: .strictJSONSchema,
                requestCount: 1,
                retryCount: 0
            )
        }
        try expectFailure(.noContent) {
            try parser.parse(
                data: chatResponse(content: ""),
                response: response(url: Self.particleChatEndpoint, status: 200),
                requestedModelID: Self.particleModelID,
                mode: .strictJSONSchema,
                requestCount: 1,
                retryCount: 0
            )
        }
    }

    @Test func choiceLevelErrorInsideHTTP200PreservesProviderCode() throws {
        let parser = CloudSQLResponseParser(profile: .openRouterTest)
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
        } catch let failure as CloudRequestFailure {
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

    @Test(arguments: Self.pinnedProfiles)
    func choiceLevelErrorTakesPrecedenceOverCanonicalValidation(profile: CloudModelProfile) throws {
        let parser = CloudSQLResponseParser(profile: profile)
        do {
            _ = try parser.parse(
                data: chatResponse(
                    content: nil,
                    model: nil,
                    choiceError: [
                        "message": "provider failed",
                        "metadata": [
                            "error_type": "provider_unavailable",
                            "provider_code": "overloaded",
                        ],
                    ]
                ),
                response: response(url: profile.chatCompletionsURL, status: 200),
                requestedModelID: profile.requestedModelID,
                mode: .strictJSONSchema,
                requestCount: 1,
                retryCount: 0
            )
            Issue.record("expected provider error")
        } catch let failure as CloudRequestFailure {
            #expect(failure.category == .providerUnavailable)
            #expect(failure.diagnostic.providerCode == "overloaded")
        }
    }

    @Test(arguments: Self.pinnedProfiles)
    func failedCompletionTakesPrecedenceOverCanonicalValidation(profile: CloudModelProfile) throws {
        let parser = CloudSQLResponseParser(profile: profile)

        try expectFailure(.providerUnavailable) {
            try parser.parse(
                data: chatResponse(content: nil, model: nil, finishReason: "error"),
                response: response(url: profile.chatCompletionsURL, status: 200),
                requestedModelID: profile.requestedModelID,
                mode: .strictJSONSchema,
                requestCount: 1,
                retryCount: 0
            )
        }
        try expectFailure(.maxTokensExceeded) {
            try parser.parse(
                data: chatResponse(content: goodContent, model: nil, finishReason: "length"),
                response: response(url: profile.chatCompletionsURL, status: 200),
                requestedModelID: profile.requestedModelID,
                mode: .strictJSONSchema,
                requestCount: 1,
                retryCount: 0
            )
        }
        try expectFailure(.contentPolicy) {
            try parser.parse(
                data: chatResponse(content: goodContent, model: nil, finishReason: "content_filter"),
                response: response(url: profile.chatCompletionsURL, status: 200),
                requestedModelID: profile.requestedModelID,
                mode: .strictJSONSchema,
                requestCount: 1,
                retryCount: 0
            )
        }
        try expectFailure(.refusal) {
            try parser.parse(
                data: chatResponse(content: goodContent, model: nil, refusal: "No."),
                response: response(url: profile.chatCompletionsURL, status: 200),
                requestedModelID: profile.requestedModelID,
                mode: .strictJSONSchema,
                requestCount: 1,
                retryCount: 0
            )
        }
        try expectFailure(.noContent) {
            try parser.parse(
                data: chatResponse(content: nil, model: nil),
                response: response(url: profile.chatCompletionsURL, status: 200),
                requestedModelID: profile.requestedModelID,
                mode: .strictJSONSchema,
                requestCount: 1,
                retryCount: 0
            )
        }
    }

    @Test(arguments: Self.pinnedProfiles)
    func identityIsCheckedBeforeTheContentIsParsed(profile: CloudModelProfile) throws {
        let parser = CloudSQLResponseParser(profile: profile)

        for mode in [StructuredOutputMode.promptOnlyJSON, .strictJSONSchema] {
            try expectFailure(.modelVersionMismatch) {
                try parser.parse(
                    data: chatResponse(content: "not json", model: "unexpected/model"),
                    response: response(url: profile.chatCompletionsURL, status: 200),
                    requestedModelID: profile.requestedModelID,
                    mode: mode,
                    requestCount: 1,
                    retryCount: 0
                )
            }
        }
    }

    @Test func particleRequiresExactlyTheParticleOneModel() throws {
        let parser = CloudSQLResponseParser(profile: .particleTest)
        // The requested alias, a sibling model, another provider's model, and
        // the expected model vouched for only by OpenRouter router metadata.
        let rejected: [(model: String?, routerMetadata: [String: Any]?)] = [
            ("particle-1", nil),
            ("particle-ai/particle-2", nil),
            ("openai/gpt-5.5", nil),
            (
                "particle-1",
                routerMetadata(
                    requestedModelID: "particle-1",
                    selectedModelIDs: [ParticleTestSupport.returnedModelID]
                )
            ),
        ]

        for (model, routerMetadata) in rejected {
            do {
                _ = try parser.parse(
                    data: chatResponse(content: goodContent, model: model, openrouterMetadata: routerMetadata),
                    response: response(url: Self.particleChatEndpoint, status: 200),
                    requestedModelID: Self.particleModelID,
                    mode: .promptOnlyJSON,
                    requestCount: 1,
                    retryCount: 0
                )
                Issue.record("expected \(model ?? "nil") to be rejected")
            } catch let failure as CloudRequestFailure {
                #expect(failure.category == .modelVersionMismatch)
                #expect(failure.pipelineCategory == .backendUnavailable)
                #expect(failure.diagnostic.returnedModelID == model)
                #expect(failure.diagnostic.requestedModelID == Self.particleModelID)
                #expect(failure.message.contains("answered with a model other than Particle-1"))
            }
        }

        let accepted = try parser.parse(
            data: particleChatResponse(content: goodContent),
            response: response(url: Self.particleChatEndpoint, status: 200),
            requestedModelID: Self.particleModelID,
            mode: .promptOnlyJSON,
            requestCount: 1,
            retryCount: 0
        )
        #expect(accepted.metadata.returnedModelID == ParticleTestSupport.returnedModelID)
    }

    @Test func particleMissingReturnedModelFailsClosedAsVersionMismatch() async throws {
        let (generator, transport) = makeGenerator(
            profile: .particleTest,
            chatResults: [
                .success((chatResponse(content: goodContent, model: nil), response(url: Self.particleChatEndpoint, status: 200))),
                .success((particleChatResponse(content: goodContent), response(url: Self.particleChatEndpoint, status: 200))),
            ]
        )

        do {
            _ = try await generator.generateSQL(
                question: "show users",
                schema: makeSchema(),
                config: SQLGenerationConfig()
            )
            Issue.record("expected model version mismatch")
        } catch let failure as CloudRequestFailure {
            #expect(failure.category == .modelVersionMismatch)
            #expect(failure.diagnostic.returnedModelID == nil)
            #expect(failure.diagnostic.attemptCount == 1)
            #expect(failure.message.contains("did not report"))
            #expect(failure.message.contains("Particle-1"))
        }
        // An identity failure is never resent.
        #expect(transport.requests.count == 1)
    }

    @Test func everyTypedFailureCategoryIsReachable() {
        let cases: [(String?, Int?, String?, CloudRequestFailure.Category)] = [
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
                CloudRequestFailure.category(
                    errorType: type,
                    httpStatus: status,
                    message: message,
                    profile: .openRouterTest
                ) == category
            )
        }
        #expect(
            CloudRequestFailure.category(
                errorType: nil,
                providerCode: "provider_limit",
                httpStatus: 400,
                message: nil,
                profile: .openRouterTest
            ) == .providerLimit
        )
        #expect(
            CloudRequestFailure.category(
                errorType: "rate_limit_exceeded",
                providerCode: "provider_limit",
                httpStatus: 429,
                message: nil,
                profile: .openRouterTest
            ) == .providerLimit
        )
        #expect(
            CloudRequestFailure.category(
                errorType: "rate_limit_exceeded",
                providerCode: "credits",
                httpStatus: 429,
                message: nil,
                profile: .openRouterTest
            ) == .paymentRequired
        )

        #expect(
            CloudRequestFailure(category: .noContent, message: "empty").category == .noContent
        )
        #expect(
            CloudRequestFailure(category: .malformedStructuredResponse, message: "bad").category
                == .malformedStructuredResponse
        )
        #expect(
            CloudRequestFailure(category: .networkTransport, message: "offline").category
                == .networkTransport
        )
    }

    @Test(arguments: Self.particleErrorRows)
    func particleErrorsMapToTheirCategories(row: ParticleErrorRow) {
        let policy = ChatCompletionRetryPolicy()
        // The typed code or type decides, even at a status that alone would
        // classify the error as an invalid request.
        for status in [row.status, 400] {
            let failure = CloudSQLResponseParser.failure(
                from: particleErrorResponse(code: row.code, type: row.type, message: "Particle error."),
                response: response(url: Self.particleChatEndpoint, status: status),
                requestedModelID: Self.particleModelID,
                attemptCount: 1,
                profile: .particleTest
            )
            #expect(failure.category == row.category, "HTTP \(status)")
            #expect(failure.diagnostic.providerCode == row.code)
            #expect(failure.diagnostic.providerErrorType == row.type)
            #expect(failure.diagnostic.httpStatus == status)

            let firstResend = policy.retryDelay(for: failure, attempt: 1, noContentRetries: 0)
            let laterResend = policy.retryDelay(
                for: failure,
                attempt: 2,
                noContentRetries: 0,
                invalidOutputRetries: 1
            )
            switch row.retry {
            case .never:
                #expect(firstResend == nil)
            case .retryable:
                #expect(firstResend != nil)
                #expect(laterResend != nil)
            case .once:
                #expect(firstResend != nil)
                #expect(laterResend == nil)
                #expect(failure.pipelineCategory == .structuredResponseParsing)
            }
        }
    }

    @Test func particleCodeOutranksTypeAndTypeOutranksStatus() {
        func failure(_ body: Data, status: Int) -> CloudRequestFailure {
            CloudSQLResponseParser.failure(
                from: body,
                response: response(url: Self.particleChatEndpoint, status: status),
                requestedModelID: Self.particleModelID,
                attemptCount: 1,
                profile: .particleTest
            )
        }

        #expect(
            failure(
                particleErrorResponse(code: "insufficient_credits", type: "rate_limit_error", message: "No credits."),
                status: 429
            ).category == .paymentRequired
        )
        #expect(
            failure(
                particleErrorResponse(code: nil, type: "authorization_error", message: "Missing scope."),
                status: 400
            ).category == .permissionDenied
        )
        let unknown = failure(
            particleErrorResponse(code: "a_new_code", type: "server_error", message: "Busy."),
            status: 503
        )
        #expect(unknown.category == .providerOverloaded)
        #expect(unknown.diagnostic.providerCode == "a_new_code")
        #expect(unknown.diagnostic.providerErrorType == "server_error")

        // A numeric code is an HTTP status, not a typed code.
        let numeric = failure(jsonData(["error": ["message": "Slow down.", "code": "429"]]), status: 200)
        #expect(numeric.category == .rateLimited)
        #expect(numeric.diagnostic.httpStatus == 429)
        #expect(numeric.diagnostic.providerCode == nil)

        let fallback = failure(Data("<html>Bad gateway</html>".utf8), status: 502)
        #expect(fallback.category == .providerUnavailable)
        #expect(fallback.message == "Particle returned HTTP 502.")
    }

    @Test func openRouterIgnoresTopLevelErrorTypeAndTypedCode() {
        func failure(_ error: [String: Any], status: Int) -> CloudRequestFailure {
            CloudSQLResponseParser.failure(
                from: jsonData(["error": error]),
                response: response(url: Self.chatEndpoint, status: status),
                requestedModelID: Self.modelID,
                attemptCount: 1,
                profile: .openRouterTest
            )
        }

        // A passed-through upstream `type` and string `code` would mean
        // authentication and out of credits on Particle; on OpenRouter only
        // `metadata` and the status classify, as before.
        let bare = failure(["message": "Upstream busy."], status: 503)
        let typed = failure(
            ["message": "Upstream busy.", "type": "authentication", "code": "payment_required"],
            status: 503
        )
        #expect(typed.category == bare.category)
        #expect(typed.diagnostic.providerErrorType == nil)
        #expect(typed.diagnostic.providerCode == nil)

        let withMetadata = failure(
            [
                "message": "Upstream busy.",
                "type": "authentication",
                "code": "payment_required",
                "metadata": ["error_type": "provider_unavailable", "provider_code": "overloaded"],
            ],
            status: 503
        )
        #expect(withMetadata.category == .providerUnavailable)
        #expect(withMetadata.diagnostic.providerErrorType == "provider_unavailable")
        #expect(withMetadata.diagnostic.providerCode == "overloaded")
    }

    @Test(arguments: [CloudModelProfile.particleTest, .openRouterTest])
    func errorEnvelopeWithANonStringTypeKeepsItsMessageAndCode(profile: CloudModelProfile) throws {
        let error: [String: Any] = profile.usesOpenRouterRouting
            ? [
                "message": "No credits left.",
                "type": ["name": "billing"],
                "code": 402,
                "metadata": ["error_type": "insufficient_credits"],
            ]
            : [
                "message": "No credits left.",
                "type": ["name": "billing"],
                "code": "insufficient_credits",
            ]

        let nonSuccess = CloudSQLResponseParser.failure(
            from: jsonData(["error": error]),
            response: response(url: profile.chatCompletionsURL, status: 402),
            requestedModelID: profile.requestedModelID,
            attemptCount: 1,
            profile: profile
        )
        #expect(nonSuccess.category == .paymentRequired)
        #expect(nonSuccess.message == "No credits left.")
        #expect(nonSuccess.diagnostic.providerErrorType == (profile.usesOpenRouterRouting ? "insufficient_credits" : nil))

        // The same envelope inside an HTTP 200 is still a provider error,
        // not a malformed response.
        do {
            _ = try CloudSQLResponseParser(profile: profile).parse(
                data: jsonData(["id": "cmpl-typed-error", "error": error]),
                response: response(url: profile.chatCompletionsURL, status: 200),
                requestedModelID: profile.requestedModelID,
                mode: .promptOnlyJSON,
                requestCount: 1,
                retryCount: 0
            )
            Issue.record("Expected a provider error")
        } catch let failure as CloudRequestFailure {
            #expect(failure.category == .paymentRequired)
            #expect(failure.message == "No credits left.")
            #expect(failure.diagnostic.completionID == "cmpl-typed-error")
        }
    }

    @Test(arguments: [CloudModelProfile.particleTest, .openRouterTest])
    func responseParsersNameTheProfileProvider(profile: CloudModelProfile) throws {
        let provider = profile.provider.displayName
        let ok = response(url: profile.chatCompletionsURL, status: 200)
        let emptyContent = jsonData([
            "id": "cmpl-empty",
            "model": ParticleTestSupport.returnedModelID,
            "choices": [[
                "index": 0,
                "finish_reason": "stop",
                "message": ["role": "assistant", "content": ""],
            ]],
        ])
        let cases: [(data: Data, message: String)] = [
            (Data("{".utf8), "\(provider) returned a malformed response envelope."),
            (jsonData(["id": "cmpl-none", "choices": [Any]()]), "\(provider) returned no choices."),
            (emptyContent, "\(provider) returned empty assistant content."),
        ]

        for (data, message) in cases {
            do {
                _ = try CloudSQLResponseParser(profile: profile).parse(
                    data: data,
                    response: ok,
                    requestedModelID: profile.requestedModelID,
                    mode: .promptOnlyJSON,
                    requestCount: 1,
                    retryCount: 0
                )
                Issue.record("Expected one-shot parse failure: \(message)")
            } catch let failure as CloudRequestFailure {
                #expect(failure.message == message)
            }
            do {
                _ = try ChatToolParser(profile: profile).parse(
                    data: data,
                    response: ok,
                    requestedModelID: profile.requestedModelID,
                    requestCount: 1,
                    retryCount: 0
                )
                Issue.record("Expected tool-turn parse failure: \(message)")
            } catch let failure as CloudRequestFailure {
                #expect(failure.message == message)
            }
        }
    }

    @Test(arguments: [CloudModelProfile.particleTest, .openRouterTest])
    func generatorHTTPBudgetMessageNamesTheProfileProvider(profile: CloudModelProfile) async throws {
        let transport = StubTransport([])
        let generator = CloudSQLGenerator(
            apiKey: "test-key",
            profile: profile,
            transport: transport,
            capabilityResolver: CloudCapabilityResolver(
                profile: profile,
                catalogService: catalogService(transport: transport)
            ),
            retryPolicy: ChatCompletionRetryPolicy(maxAttempts: 1),
            countCapabilityLookupHTTPAttempts: true
        )

        do {
            _ = try await generator.generateSQL(
                question: "List users",
                schema: makeSchema(),
                context: SQLGenerationContext(mode: .repair, modelCallCount: 2),
                config: SQLGenerationConfig()
            )
            Issue.record("Expected HTTP-attempt budget exhaustion.")
        } catch let failure as HTTPAttemptBudgetExhausted {
            #expect(failure.message == "\(profile.provider.displayName) HTTP-attempt budget exhausted before generation.")
            #expect(transport.requests.isEmpty)
        }
    }

    @Test func openRouterMessageWordingReclassifiesOnlyOpenRouterFailures() {
        func category(_ message: String, status: Int, profile: CloudModelProfile) -> CloudRequestFailure.Category {
            CloudSQLResponseParser.failure(
                from: jsonData(["error": ["message": message]]),
                response: response(url: profile.chatCompletionsURL, status: status),
                requestedModelID: profile.requestedModelID,
                attemptCount: 1,
                profile: profile
            ).category
        }

        // A 402 that mentions credits is out of credits on Particle; only
        // OpenRouter's key-limit wording means a provider budget.
        #expect(category("Insufficient credits remaining for this key", status: 402, profile: .particleTest) == .paymentRequired)
        #expect(category("Insufficient credits remaining for this key", status: 402, profile: .openRouterTest) == .providerLimit)
        #expect(category("Key limit exceeded (total limit).", status: 403, profile: .particleTest) == .permissionDenied)
        #expect(category("Key limit exceeded (total limit).", status: 403, profile: .openRouterTest) == .providerLimit)
        #expect(category("High demand during peak load.", status: 500, profile: .particleTest) == .serverFailure)
        #expect(category("High demand during peak load.", status: 500, profile: .openRouterTest) == .providerOverloaded)

        let routing = CloudSQLResponseParser.failure(
            from: jsonData(["error": ["message": "No endpoints found matching your data policy."]]),
            response: response(url: Self.particleChatEndpoint, status: 404),
            requestedModelID: Self.particleModelID,
            attemptCount: 1,
            profile: .particleTest
        )
        #expect(routing.category == .modelNotFound)
        #expect(!routing.message.contains("private-routing requirements"))

        // OpenRouter's numeric code and metadata keep their old meaning, and
        // Particle's codes mean nothing there.
        let openRouter = CloudSQLResponseParser.failure(
            from: jsonData(["error": ["message": "Busy.", "code": "fleet_capacity_exhausted"]]),
            response: response(url: Self.chatEndpoint, status: 503),
            requestedModelID: Self.modelID,
            attemptCount: 1,
            profile: .openRouterTest
        )
        #expect(openRouter.category == .providerOverloaded)
        #expect(openRouter.diagnostic.providerCode == nil)
        #expect(
            CloudSQLResponseParser.failure(
                from: Data(),
                response: response(url: Self.chatEndpoint, status: 500),
                requestedModelID: Self.modelID,
                attemptCount: 1,
                profile: .openRouterTest
            ).message == "OpenRouter returned HTTP 500."
        )
    }

    @Test func invalidModelOutputIsResentOnceWithACorrectiveMessage() async throws {
        let (generator, transport) = makeGenerator(
            profile: .particleTest,
            chatResults: [
                .success((invalidModelOutputResponse(), response(url: Self.particleChatEndpoint, status: 502, headers: ["Retry-After": "0"]))),
                .success((particleChatResponse(content: goodContent), response(url: Self.particleChatEndpoint, status: 200))),
            ]
        )

        let result = try await generator.generateSQL(
            question: "show users",
            schema: makeSchema(),
            config: SQLGenerationConfig()
        )

        #expect(result.backendMetadata?.requestCount == 2)
        #expect(result.backendMetadata?.retryCount == 1)
        #expect(result.generationCallCount == 2)
        let messages = try transport.requests.map { request in
            try #require(try jsonBody(request)["messages"] as? [[String: String]])
        }
        #expect(messages.map(\.count) == [2, 3])
        #expect(Array(messages[1].prefix(2)) == messages[0])
        #expect(messages[1].last?["role"] == "user")
        #expect(messages[1].last?["content"] == CloudSQLGenerator.invalidOutputCorrection)
        #expect(CloudSQLGenerator.invalidOutputCorrection.contains("exactly one valid JSON object"))
        // The corrected resend is still a Particle one-shot request in the
        // same run, so it keeps the run's cache key.
        for request in transport.requests {
            try ParticleTestSupport.expectRequestShape(request, callSite: .oneShotSQL)
        }
        let keys = try transport.requests.compactMap { try ParticleTestSupport.promptCacheKey(in: $0) }
        #expect(Set(keys).count == 1)
    }

    @Test func repeatedInvalidModelOutputFailsAsStructuredResponseParsing() async throws {
        let (generator, transport) = makeGenerator(
            profile: .particleTest,
            chatResults: Array(
                repeating: .success((invalidModelOutputResponse(), response(url: Self.particleChatEndpoint, status: 502, headers: ["Retry-After": "0"]))),
                count: 3
            )
        )

        do {
            _ = try await generator.generateSQL(
                question: "show users",
                schema: makeSchema(),
                config: SQLGenerationConfig()
            )
            Issue.record("expected invalid model output failure")
        } catch let failure as CloudRequestFailure {
            #expect(failure.category == .malformedStructuredResponse)
            #expect(failure.diagnostic.providerCode == "invalid_model_output")
            #expect(failure.diagnostic.attemptCount == 2)
            #expect(failure.pipelineCategory == .structuredResponseParsing)
            #expect(SQLGenerationFailure.typed(failure)?.pipelineCategory == .structuredResponseParsing)
        }
        // Resent exactly once, leaving the third attempt unused.
        #expect(transport.requests.count == 2)
    }

    @Test func particleRateLimitWaitsForRetryAfterOneSecond() async throws {
        let rateLimited = particleErrorResponse(
            code: "fleet_capacity_exhausted",
            type: "rate_limit_error",
            message: "Fleet capacity exhausted."
        )
        let (generator, transport) = makeGenerator(
            profile: .particleTest,
            chatResults: [
                .success((rateLimited, response(url: Self.particleChatEndpoint, status: 429, headers: ["Retry-After": "1"]))),
                .success((particleChatResponse(content: goodContent), response(url: Self.particleChatEndpoint, status: 200))),
            ]
        )

        let started = Date()
        let result = try await generator.generateSQL(
            question: "show users",
            schema: makeSchema(),
            config: SQLGenerationConfig()
        )

        #expect(Date().timeIntervalSince(started) >= 0.95)
        #expect(result.backendMetadata?.retryCount == 1)
        #expect(transport.requests.count == 2)
        let failure = CloudRequestFailure(category: .rateLimited, message: "Slow down.", retryAfterSeconds: 1)
        #expect(ChatCompletionRetryPolicy().retryDelay(for: failure, attempt: 1, noContentRetries: 0) == 1)
    }

    @Test func failureDiagnosticKeepsItsSavedJSONKeys() throws {
        let failure = CloudRequestFailure(
            category: .paymentRequired,
            message: "Payment required.",
            httpStatus: 402,
            providerErrorType: "insufficient_credits",
            providerCode: "credits",
            completionID: "gen-1",
            requestID: "req-1",
            requestedModelID: Self.modelID,
            returnedModelID: Self.modelID,
            providerName: "OpenAI",
            retryAfterSeconds: 1,
            suggestedWaitSeconds: 2,
            promptTokens: 10,
            completionTokens: 5,
            reasoningTokens: 1,
            totalTokens: 15,
            costUSD: 0.01,
            attemptCount: 2
        )

        // Saved pipeline failures and eval results wrote these keys; the
        // renamed providerErrorType must still encode as openRouterErrorType.
        let data = try JSONEncoder().encode(failure.diagnostic)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["openRouterErrorType"] as? String == "insufficient_credits")
        #expect(
            Set(object.keys) == [
                "category", "httpStatus", "openRouterErrorType", "providerCode", "completionID",
                "requestID", "requestedModelID", "returnedModelID", "providerName",
                "retryAfterSeconds", "suggestedWaitSeconds", "promptTokens", "completionTokens",
                "reasoningTokens", "totalTokens", "costUSD", "attemptCount",
            ]
        )
        #expect(
            try JSONDecoder().decode(CloudRequestFailureDiagnostic.self, from: data) == failure.diagnostic
        )

        let saved = Data(
            #"{"category":"paymentRequired","openRouterErrorType":"insufficient_credits","attemptCount":1}"#.utf8
        )
        let decoded = try JSONDecoder().decode(CloudRequestFailureDiagnostic.self, from: saved)
        #expect(decoded.providerErrorType == "insufficient_credits")
    }

    @Test func retryAfterSecondsHTTPDateAndCapAreHandled() {
        let policy = ChatCompletionRetryPolicy()
        let seconds = policy.retryAfter(
            from: response(url: Self.chatEndpoint, status: 429, headers: ["Retry-After": "3"])
        )
        let date = Date(timeIntervalSinceNow: 2)
        let httpDate = Self.httpDateFormatter.string(from: date)
        let dateDelay = policy.retryAfter(
            from: response(url: Self.chatEndpoint, status: 429, headers: ["Retry-After": httpDate])
        )
        let capped = policy.retryDelay(
            for: CloudRequestFailure(
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
        let policy = ChatCompletionRetryPolicy(maxAttempts: 1)
        let failure = CloudRequestFailure(
            category: .rateLimited,
            message: "Retry later.",
            httpStatus: 429
        )

        #expect(policy.retryDelay(for: failure, attempt: 1, noContentRetries: 0) == nil)
    }

        @Test(arguments: Self.chatProfiles)
    func retriesTransientFailuresAndCountsEveryAttempt(profile: CloudModelProfile) async throws {
        let (generator, transport) = makeGenerator(
            profile: profile,
            chatResults: [
                .success((transientErrorResponse(for: profile), response(url: profile.chatCompletionsURL, status: 503, headers: ["Retry-After": "0"]))),
                .success((transientErrorResponse(for: profile), response(url: profile.chatCompletionsURL, status: 503, headers: ["Retry-After": "0"]))),
                .success((chatResponse(for: profile, content: goodContent), response(url: profile.chatCompletionsURL, status: 200))),
            ]
        )
        let result = try await generator.generateSQL(
            question: "show users",
            schema: makeSchema(),
            config: SQLGenerationConfig()
        )

        #expect(result.generationCallCount == 3)
        #expect(result.backendMetadata?.requestCount == 3)
        #expect(result.backendMetadata?.retryCount == 2)
        let chatRequests = transport.requests.filter { $0.url == profile.chatCompletionsURL }
        #expect(chatRequests.count == 3)
        for request in chatRequests {
            try expectProviderRequest(request, profile: profile)
        }
    }

        @Test(arguments: Self.chatProfiles)
    func retryMetadataIncludesUsageFromFailedCompletion(profile: CloudModelProfile) async throws {
        let (generator, _) = makeGenerator(
            profile: profile,
            chatResults: [
                .success((chatResponse(for: profile, content: ""), response(url: profile.chatCompletionsURL, status: 200, headers: ["Retry-After": "0"]))),
                .success((chatResponse(for: profile, content: goodContent), response(url: profile.chatCompletionsURL, status: 200))),
            ]
        )

        let result = try await generator.generateSQL(
            question: "show users",
            schema: makeSchema(),
            config: SQLGenerationConfig()
        )

        #expect(result.backendMetadata?.requestCount == 2)
        #expect(result.backendMetadata?.retryCount == 1)
        #expect(result.backendMetadata?.promptTokens == 22)
        #expect(result.backendMetadata?.completionTokens == 44)
        #expect(result.backendMetadata?.reasoningTokens == 6)
        #expect(result.backendMetadata?.totalTokens == 66)
        // OpenRouter reports usage.cost. Particle doesn't, so each attempt's
        // 11 prompt and 22 completion tokens are priced at $0.25 and $1.00
        // per 1M tokens.
        let expectedCost = profile.reportsUsageCost ? 0.00024 : 2 * (11 * 0.25 + 22 * 1.00) / 1_000_000
        #expect(abs((result.backendMetadata?.costUSD ?? 0) - expectedCost) < 1e-12)
        #expect(
            result.backendMetadata?.costSource
                == (profile.reportsUsageCost ? "reported" : "estimatedPeakList")
        )
    }

    @Test func particlePricingBillsCachedPromptTokensEightTimesCheaper() throws {
        let pricing = try #require(CloudModelProfile.particle.pricing)
        let uncached = pricing.estimatedCostUSD(prompt: 1_000_000, cached: 0, completion: 0)
        let cached = pricing.estimatedCostUSD(prompt: 1_000_000, cached: 1_000_000, completion: 0)

        #expect(abs(uncached - 0.25) < 1e-12)
        #expect(abs(cached - 0.03) < 1e-12)
        #expect(cached * 8 < uncached)
        #expect(abs(pricing.estimatedCostUSD(prompt: 0, cached: 0, completion: 1_000_000) - 1.00) < 1e-12)
        // 2,000 uncached, 8,000 cached and 1,000 completion tokens.
        #expect(
            abs(pricing.estimatedCostUSD(prompt: 10_000, cached: 8_000, completion: 1_000) - 0.00174)
                < 1e-12
        )
        #expect(pricing.estimatedCostUSD(prompt: 0, cached: 0, completion: 0) == 0)
    }

    @Test func reportedUsageCostWinsOverTheTokenEstimate() throws {
        let reported = try JSONDecoder().decode(
            ChatCompletionUsage.self,
            from: Data(
                #"{"prompt_tokens":1000,"completion_tokens":100,"prompt_tokens_details":{"cached_tokens":400},"cost":0.5}"#.utf8
            )
        ).priced(by: .particleTest)
        #expect(reported.cachedTokens == 400)
        #expect(reported.costUSD == 0.5)
        #expect(reported.costSource == "reported")

        let unreported = try JSONDecoder().decode(
            ChatCompletionUsage.self,
            from: Data(#"{"prompt_tokens":1000,"completion_tokens":100}"#.utf8)
        )
        #expect(unreported.costUSD == nil)
        #expect(unreported.costSource == nil)
        // An OpenRouter profile has no prices, so it never estimates.
        #expect(unreported.priced(by: .openRouterTest).costUSD == nil)
        let estimated = unreported.priced(by: .particleTest)
        #expect(abs((estimated.costUSD ?? 0) - (1000 * 0.25 + 100 * 1.00) / 1_000_000) < 1e-12)
        #expect(estimated.costSource == "estimatedPeakList")

        let parsed = try CloudSQLResponseParser(profile: .particleTest).parse(
            data: particleChatResponse(content: goodContent, cost: 0.5),
            response: response(url: Self.particleChatEndpoint, status: 200),
            requestedModelID: Self.particleModelID,
            mode: .promptOnlyJSON,
            requestCount: 1,
            retryCount: 0
        )
        #expect(parsed.metadata.costUSD == 0.5)
        #expect(parsed.metadata.costSource == "reported")
    }

    @Test func costSourceOfASumIsAnEstimateWhenAnyPartIs() {
        let reported = CloudCostSource.reported.rawValue
        let estimated = CloudCostSource.estimatedPeakList.rawValue

        #expect(CloudCostSource.combined(nil, nil) == nil)
        #expect(CloudCostSource.combined(reported, nil) == reported)
        #expect(CloudCostSource.combined(nil, estimated) == estimated)
        #expect(CloudCostSource.combined(reported, reported) == reported)
        #expect(CloudCostSource.combined(reported, estimated) == estimated)
        #expect(CloudCostSource.combined(estimated, reported) == estimated)
    }

    @Test func particleUsageEventCarriesTheTokenCostEstimate() async throws {
        let (generator, _) = makeGenerator(
            profile: .particleTest,
            chatResults: [
                .success((particleChatResponse(content: goodContent, cachedTokens: 8), response(url: Self.particleChatEndpoint, status: 200))),
            ]
        )
        let events = UsageEventRecorder()
        var config = SQLGenerationConfig()
        config.usageSink = { events.record($0) }

        let result = try await generator.generateSQL(
            question: "show users",
            schema: makeSchema(),
            config: config
        )

        // 3 uncached and 8 cached prompt tokens, and 22 completion tokens.
        let expectedCost = (3 * 0.25 + 8 * 0.03 + 22 * 1.00) / 1_000_000
        let usage = try #require(events.events.first { $0.httpAttemptCount == 0 })
        #expect(usage.promptTokens == 11)
        #expect(usage.cachedPromptTokens == 8)
        #expect(abs((usage.costUSD ?? 0) - expectedCost) < 1e-12)
        #expect(usage.costSource == "estimatedPeakList")

        let metadata = try #require(result.backendMetadata)
        #expect(metadata.cachedPromptTokens == 8)
        #expect(metadata.costUSD == usage.costUSD)
        #expect(metadata.costSource == "estimatedPeakList")
        #expect(metadata.providerID == "particle")
        #expect(metadata.reasoningEffort == "high")
        #expect(metadata.structuredOutputMode == .promptOnlyJSON)
        #expect(metadata.responseFormatType == "json_object")
    }

    @Test func failedParticleCompletionsKeepTheirEstimatedCost() async throws {
        let (generator, transport) = makeGenerator(
            profile: .particleTest,
            chatResults: Array(
                repeating: .success((particleChatResponse(content: "", cachedTokens: 4), response(url: Self.particleChatEndpoint, status: 200, headers: ["Retry-After": "0"]))),
                count: 2
            )
        )

        do {
            _ = try await generator.generateSQL(
                question: "show users",
                schema: makeSchema(),
                config: SQLGenerationConfig()
            )
            Issue.record("expected empty content failure")
        } catch let failure as CloudRequestFailure {
            #expect(failure.category == .noContent)
            #expect(failure.diagnostic.attemptCount == 2)
            // Each billed attempt: 7 uncached and 4 cached prompt tokens, and
            // 22 completion tokens.
            let perAttempt = (7 * 0.25 + 4 * 0.03 + 22 * 1.00) / 1_000_000
            #expect(abs((failure.diagnostic.costUSD ?? 0) - 2 * perAttempt) < 1e-12)
            #expect(failure.diagnostic.costSource == "estimatedPeakList")
            #expect(failure.diagnostic.cachedPromptTokens == 8)
            #expect(failure.diagnostic.promptTokens == 22)
        }
        #expect(transport.requests.count == 2)
    }

    @Test func costAndRequestSettingFieldsRoundTripAndStayOmittedWhenNil() throws {
        let bare = CloudGenerationMetadata(
            requestedModelID: Self.particleModelID,
            structuredOutputMode: .promptOnlyJSON,
            requestCount: 1,
            retryCount: 0
        )
        let bareObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(bare)) as? [String: Any]
        )
        #expect(Set(bareObject.keys) == ["requestedModelID", "structuredOutputMode", "requestCount", "retryCount"])

        var metadata = bare
        metadata.providerID = "particle"
        metadata.responseFormatType = "json_object"
        metadata.reasoningEffort = "high"
        metadata.cachedPromptTokens = 8
        metadata.costUSD = 0.001
        metadata.costSource = "estimatedPeakList"
        let data = try JSONEncoder().encode(metadata)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["providerID"] as? String == "particle")
        #expect(object["responseFormatType"] as? String == "json_object")
        #expect(object["reasoningEffort"] as? String == "high")
        #expect(object["cachedPromptTokens"] as? Int == 8)
        #expect(object["costSource"] as? String == "estimatedPeakList")
        #expect(try JSONDecoder().decode(CloudGenerationMetadata.self, from: data) == metadata)

        let failure = CloudRequestFailure(
            category: .noContent,
            message: "Empty.",
            cachedPromptTokens: 8,
            costUSD: 0.001,
            costSource: "estimatedPeakList"
        )
        let diagnosticData = try JSONEncoder().encode(failure.diagnostic)
        let diagnostic = try #require(
            JSONSerialization.jsonObject(with: diagnosticData) as? [String: Any]
        )
        #expect(diagnostic["cachedPromptTokens"] as? Int == 8)
        #expect(diagnostic["costSource"] as? String == "estimatedPeakList")
        #expect(
            try JSONDecoder().decode(CloudRequestFailureDiagnostic.self, from: diagnosticData)
                == failure.diagnostic
        )
    }

    @Test func repairCompletionRequiresPrivateRouting() async throws {
        let transport = StubTransport([
            .success((catalogResponse(), response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200))),
            .success((chatResponse(content: goodContent), response(url: Self.chatEndpoint, status: 200))),
        ])

        _ = try await makeGenerator(transport: transport).generateSQL(
            question: "repair the users query",
            schema: makeSchema(),
            context: SQLGenerationContext(
                mode: .repair,
                currentSQL: "SELECT missing FROM public.users",
                lastRunError: "column missing does not exist",
                repairContext: SQLRepairContext(
                    failedSQL: "SELECT missing FROM public.users"
                )
            ),
            config: SQLGenerationConfig()
        )

        let request = try #require(
            transport.requests.first { $0.url?.path == "/api/v1/chat/completions" }
        )
        try expectPrivateRouting(in: request)
    }

    @Test func privateEndpointUnavailabilityFailsClosed() async throws {
        let transport = StubTransport([
            .success((catalogResponse(), response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200))),
            .success((
                errorResponse(
                    errorType: "provider_unavailable",
                    message: "No private endpoint supports all required parameters."
                ),
                response(url: Self.chatEndpoint, status: 503)
            )),
        ])

        do {
            _ = try await makeGenerator(
                transport: transport,
                retryPolicy: ChatCompletionRetryPolicy(maxAttempts: 1)
            ).generateSQL(
                question: "show users",
                schema: makeSchema(),
                config: SQLGenerationConfig()
            )
            Issue.record("expected provider availability failure")
        } catch let failure as CloudRequestFailure {
            #expect(failure.category == .providerUnavailable)
        }

        let chatRequests = transport.requests.filter { $0.url?.path == "/api/v1/chat/completions" }
        #expect(chatRequests.count == 1)
        try expectPrivateRouting(in: try #require(chatRequests.first))
    }

        @Test(arguments: Self.chatProfiles)
    func retriesServerFailuresAndCountsAttempts(profile: CloudModelProfile) async throws {
        let (generator, transport) = makeGenerator(
            profile: profile,
            chatResults: [
                .success((serverErrorResponse(for: profile), response(url: profile.chatCompletionsURL, status: 500, headers: ["Retry-After": "0"]))),
                .success((chatResponse(for: profile, content: goodContent), response(url: profile.chatCompletionsURL, status: 200))),
            ]
        )
        let result = try await generator.generateSQL(
            question: "show users",
            schema: makeSchema(),
            config: SQLGenerationConfig()
        )

        #expect(result.generationCallCount == 2)
        #expect(result.backendMetadata?.requestCount == 2)
        #expect(result.backendMetadata?.retryCount == 1)
        #expect(transport.requests.filter { $0.url == profile.chatCompletionsURL }.count == 2)
    }

        @Test(arguments: Self.chatProfiles)
    func retryCapStopsAfterThreeHTTPAttempts(profile: CloudModelProfile) async throws {
        let (generator, transport) = makeGenerator(
            profile: profile,
            chatResults: Array(
                repeating: .success((transientErrorResponse(for: profile), response(url: profile.chatCompletionsURL, status: 503, headers: ["Retry-After": "0"]))),
                count: 3
            )
        )

        do {
            _ = try await generator.generateSQL(
                question: "show users",
                schema: makeSchema(),
                config: SQLGenerationConfig()
            )
            Issue.record("expected provider failure")
        } catch let failure as CloudRequestFailure {
            // OpenRouter's provider_unavailable type and Particle's
            // model_unavailable code both outrank the 503 status.
            #expect(failure.category == .providerUnavailable)
            #expect(failure.diagnostic.attemptCount == 3)
        }
        #expect(transport.requests.filter { $0.url == profile.chatCompletionsURL }.count == 3)
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

        let (backoffGenerator, backoffTransport) = makeGenerator(
            profile: .particleTest,
            chatResults: [
                .success((transientErrorResponse(for: .particleTest), response(url: Self.particleChatEndpoint, status: 503, headers: ["Retry-After": "10"]))),
            ]
        )
        let backoffTask = Task {
            try await backoffGenerator.generateSQL(
                question: "show users",
                schema: makeSchema(),
                config: SQLGenerationConfig()
            )
        }
        while backoffTransport.requests.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        backoffTask.cancel()
        await expectCancellation(backoffTask)
    }

    @Test func particleOneShotRequestSendsOnlyParticleParameters() throws {
        let profile = CloudModelProfile.particleTest
        guard case .staticCapabilities(let capabilities) = profile.capabilityResolution else {
            Issue.record("expected static Particle capabilities")
            return
        }
        let builder = ChatCompletionRequestBuilder(profile: profile)

        let built = try builder.build(
            apiKey: "pai-test",
            instructions: "instructions",
            prompt: "prompt",
            capabilities: capabilities,
            promptCacheKey: "widen-run"
        )
        let body = try ParticleTestSupport.expectRequestShape(built.request, callSite: .oneShotSQL)
        #expect(built.mode == .promptOnlyJSON)
        #expect(body["reasoning_effort"] as? String == "high")
        #expect(body["max_completion_tokens"] as? Int == 16_000)
        #expect(body["prompt_cache_key"] as? String == "widen-run")
        #expect((body["response_format"] as? [String: Any])?.count == 1)

        let probe = try builder.buildTinyJSONTest(apiKey: "pai-test", capabilities: capabilities)
        let probeBody = try ParticleTestSupport.expectRequestShape(
            probe.request,
            callSite: .connectivityProbe,
            requiresPromptCacheKey: false
        )
        #expect(probeBody["reasoning_effort"] as? String == "none")
        #expect(probeBody["max_completion_tokens"] as? Int == 256)
    }

    @Test func particleOneShotRunsShareOneCacheKeyAcrossRetriesButNotAcrossRuns() async throws {
        let (generator, transport) = makeGenerator(
            profile: .particleTest,
            chatResults: [
                .success((transientErrorResponse(for: .particleTest), response(url: Self.particleChatEndpoint, status: 503, headers: ["Retry-After": "0"]))),
                .success((particleChatResponse(content: goodContent), response(url: Self.particleChatEndpoint, status: 200))),
                .success((particleChatResponse(content: goodContent), response(url: Self.particleChatEndpoint, status: 200))),
            ]
        )

        for _ in 0..<2 {
            _ = try await generator.generateSQL(
                question: "show users",
                schema: makeSchema(),
                config: SQLGenerationConfig()
            )
        }

        let keys = try transport.requests.compactMap { try ParticleTestSupport.promptCacheKey(in: $0) }
        #expect(keys.count == 3)
        #expect(keys[0] == keys[1])
        #expect(keys[1] != keys[2])
        for request in transport.requests {
            try ParticleTestSupport.expectRequestShape(request, callSite: .oneShotSQL)
        }
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
        var capabilities = CloudModelCapabilities.conservative()
        capabilities.supportsStructuredOutputs = true
        let request = try ChatCompletionRequestBuilder(profile: .openRouterTest).buildTinyJSONTest(
            apiKey: "test-key",
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
        try expectPrivateRouting(in: request)
    }

    @Test func connectivityMarksSingleLookupModelAvailableAfterSuccessfulTest() async throws {
        let model = "custom/model"
        let transport = StubTransport([
            .success((catalogResponse(id: "openai/other"), response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200))),
            .success((singleModelResponse(id: model), response(url: Self.apiBase.appendingPathComponent("model/custom/model"), status: 200))),
            .success((chatResponse(content: goodContent), response(url: Self.chatEndpoint, status: 200))),
        ])
        let service = catalogService(transport: transport)

        let result = await OpenRouterConnectivityCheck(
            apiKey: "test-key",
            profile: .openRouterTest.requestingModel(model),
            catalogService: service,
            transport: transport
        ).run()

        #expect(result.error == nil)
        #expect(result.selectedModelAvailable)
        #expect(result.capabilities.supportsMaxTokens)
        // The shared lookup serves the model from one forced catalog fetch
        // plus the single-model fallback; the old hand-rolled matcher fetched
        // the catalog twice.
        #expect(
            transport.requests.map { $0.url?.path } == [
                "/api/v1/models/user",
                "/api/v1/model/custom/model",
                "/api/v1/chat/completions",
            ]
        )
    }

    @Test func connectivityCheckReportsCanonicalModelMismatch() async throws {
        let expectedModelID = "openai/gpt-5.5-20260423"
        let returnedModelID = "openai/gpt-5.5-unevaluated"
        let transport = StubTransport([
            .success((
                catalogResponse(id: Self.modelID, canonicalID: expectedModelID),
                response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200)
            )),
            .success((
                chatResponse(content: goodContent, model: returnedModelID),
                response(url: Self.chatEndpoint, status: 200)
            )),
        ])
        let result = await runConnectivityCheck(
            transport: transport,
            expectedCanonicalModelID: expectedModelID
        )

        #expect(result.error?.category == .modelVersionMismatch)
        #expect(result.returnedModelID == returnedModelID)
        #expect(!result.selectedModelAvailable)
    }

    @Test func connectivityCheckAcceptsMatchingCanonicalModel() async throws {
        let expectedModelID = "openai/gpt-5.5-20260423"
        let transport = StubTransport([
            .success((
                catalogResponse(id: Self.modelID, canonicalID: expectedModelID),
                response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200)
            )),
            .success((
                chatResponse(content: goodContent, model: expectedModelID),
                response(url: Self.chatEndpoint, status: 200)
            )),
        ])
        let result = await runConnectivityCheck(
            transport: transport,
            expectedCanonicalModelID: expectedModelID
        )

        #expect(result.error == nil)
        #expect(result.selectedModelAvailable)
        #expect(result.returnedModelID == expectedModelID)
    }

    @Test func connectivityCheckRejectsCanonicalRolloverBeforeCompletionRequest() async throws {
        let expectedModelID = "openai/gpt-5.5-20260423"
        let returnedModelID = "openai/gpt-5.5-20260901"
        let transport = StubTransport([
            .success((
                catalogResponse(id: Self.modelID, canonicalID: returnedModelID),
                response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200)
            )),
        ])
        let result = await runConnectivityCheck(
            transport: transport,
            expectedCanonicalModelID: expectedModelID
        )

        #expect(result.error?.category == .modelVersionMismatch)
        #expect(result.returnedModelID == returnedModelID)
        #expect(!result.selectedModelAvailable)
        #expect(transport.requests.map { $0.url?.path } == ["/api/v1/models/user"])
    }

    @Test func missingReturnedModelFailsClosedAsVersionMismatch() async throws {
        let expectedModelID = "openai/gpt-5.5-20260423"
        let transport = StubTransport([
            .success((
                catalogResponse(id: Self.modelID, canonicalID: expectedModelID),
                response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200)
            )),
            .success((
                chatResponse(content: goodContent, model: nil),
                response(url: Self.chatEndpoint, status: 200)
            )),
        ])
        let service = catalogService(transport: transport)

        let result = await OpenRouterConnectivityCheck(
            apiKey: "test-key",
            profile: .openRouterTest.pinningReturnedModel(expectedModelID),
            catalogService: service,
            transport: transport
        ).run()

        #expect(result.error?.category == .modelVersionMismatch)
        #expect(result.returnedModelID == nil)
        #expect(result.error?.message.contains("did not report") == true)
    }

    @Test func preflightRejectsCanonicalRolloverBeforeCompletionRequest() async throws {
        let transport = StubTransport([
            .success((
                catalogResponse(id: Self.modelID, canonicalID: "openai/gpt-5.5-20260901"),
                response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200)
            )),
        ])
        let profile = CloudModelProfile.openRouterTest.pinningReturnedModel("openai/gpt-5.5-20260423")
        let generator = CloudSQLGenerator(
            apiKey: "test-key",
            profile: profile,
            transport: transport,
            capabilityResolver: CloudCapabilityResolver(
                profile: profile,
                catalogService: catalogService(transport: transport)
            )
        )

        do {
            _ = try await generator.generateSQL(
                question: "show users",
                schema: makeSchema(),
                config: SQLGenerationConfig()
            )
            Issue.record("expected canonical rollover failure")
        } catch let failure as CloudRequestFailure {
            #expect(failure.category == .modelVersionMismatch)
            #expect(failure.diagnostic.returnedModelID == "openai/gpt-5.5-20260901")
            #expect(failure.diagnostic.attemptCount == 1)
        }

        // A network-fresh mismatch is authoritative: no recovery refetch and
        // no billed completion request.
        #expect(transport.requests.map { $0.url?.path } == ["/api/v1/models/user"])
    }

    @Test func networkFreshCanonicalMismatchIsMemoizedForCatalogTTL() async {
        let transport = StubTransport([
            .success((
                catalogResponse(id: Self.modelID, canonicalID: "openai/gpt-5.5-20260901"),
                response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200)
            )),
        ])
        let service = catalogService(transport: transport, ttl: 60)

        await expectCanonicalMismatch(service: service, expectedAttemptCount: 1)
        await expectCanonicalMismatch(service: service, expectedAttemptCount: 0)

        #expect(transport.requests.map { $0.url?.path } == ["/api/v1/models/user"])
    }

    @Test func cacheServedCanonicalMismatchRefetchesOnceBeforeMemoizing() async throws {
        let transport = StubTransport([
            .success((
                catalogResponse(id: Self.modelID, canonicalID: "openai/gpt-5.5-20260901"),
                response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200)
            )),
            .success((
                catalogResponse(id: Self.modelID, canonicalID: "openai/gpt-5.5-20260901"),
                response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200)
            )),
        ])
        let service = catalogService(transport: transport, ttl: 60)
        _ = try await service.availableModels(apiKey: "test-key", forceRefresh: true)

        await expectCanonicalMismatch(service: service, expectedAttemptCount: 1)
        await expectCanonicalMismatch(service: service, expectedAttemptCount: 0)

        #expect(
            transport.requests.map { $0.url?.path } == [
                "/api/v1/models/user",
                "/api/v1/models/user",
            ]
        )
    }

    @Test func confirmedCanonicalMismatchReverifiesAfterCatalogTTLExpires() async {
        let transport = StubTransport([
            .success((
                catalogResponse(id: Self.modelID, canonicalID: "openai/gpt-5.5-20260901"),
                response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200)
            )),
            .success((
                catalogResponse(id: Self.modelID, canonicalID: "openai/gpt-5.5-20260901"),
                response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200)
            )),
        ])
        let service = catalogService(transport: transport, ttl: -1)

        await expectCanonicalMismatch(service: service, expectedAttemptCount: 1)
        await expectCanonicalMismatch(service: service, expectedAttemptCount: 1)

        #expect(
            transport.requests.map { $0.url?.path } == [
                "/api/v1/models/user",
                "/api/v1/models/user",
            ]
        )
    }

    @Test func preflightRecoversWhenStaleCacheHoldsPreviousCanonical() async throws {
        let cacheURL = temporaryCacheURL()
        let transport = StubTransport([
            .success((
                catalogResponse(id: Self.modelID, canonicalID: "openai/gpt-5.5-20260101"),
                response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200)
            )),
            .success((
                catalogResponse(id: Self.modelID, canonicalID: "openai/gpt-5.5-20260423"),
                response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200)
            )),
            .success((
                chatResponse(content: goodContent, model: "openai/gpt-5.5-20260423"),
                response(url: Self.chatEndpoint, status: 200)
            )),
        ])
        let service = catalogService(transport: transport, cacheURL: cacheURL, ttl: 60)
        _ = try await service.availableModels(apiKey: "test-key", forceRefresh: true)

        let profile = CloudModelProfile.openRouterTest.pinningReturnedModel("openai/gpt-5.5-20260423")
        let generator = CloudSQLGenerator(
            apiKey: "test-key",
            profile: profile,
            transport: transport,
            capabilityResolver: CloudCapabilityResolver(profile: profile, catalogService: service)
        )

        let result = try await generator.generateSQL(
            question: "show users",
            schema: makeSchema(),
            config: SQLGenerationConfig()
        )

        #expect(result.sql == "SELECT id FROM public.users LIMIT 100")
        #expect(
            transport.requests.map { $0.url?.path } == [
                "/api/v1/models/user",
                "/api/v1/models/user",
                "/api/v1/chat/completions",
            ]
        )
    }

    @Test func preflightDefersToPostResponseCheckWithoutPositiveMetadata() throws {
        try OpenRouterCanonicalModelValidator.preflight(
            catalogCanonicalModelID: "openai/gpt-5.5-20260901",
            capabilitySource: .staleCache,
            expectedCanonicalModelID: "openai/gpt-5.5-20260423",
            requestedModelID: "openai/gpt-5.5"
        )
        try OpenRouterCanonicalModelValidator.preflight(
            catalogCanonicalModelID: nil,
            capabilitySource: .conservativeDefault,
            expectedCanonicalModelID: "openai/gpt-5.5-20260423",
            requestedModelID: "openai/gpt-5.5"
        )
        try OpenRouterCanonicalModelValidator.preflight(
            catalogCanonicalModelID: "openai/gpt-5.5-20260423",
            capabilitySource: .authenticatedCatalog,
            expectedCanonicalModelID: "openai/gpt-5.5-20260423",
            requestedModelID: "openai/gpt-5.5"
        )
    }

    @Test func catalogLookupCanExhaustHTTPBudgetBeforeChatRequest() async throws {
        let transport = StubTransport([
            .success((catalogResponse(), response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200)))
        ])
        let generator = makeGenerator(
            transport: transport,
            retryPolicy: ChatCompletionRetryPolicy(maxAttempts: 1),
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
        } catch let failure as HTTPAttemptBudgetExhausted {
            #expect(failure.backendMetadata?.requestCount == 1)
            #expect(transport.requests.map { $0.url?.path } == ["/api/v1/models/user"])
        }
    }

    @Test func repairContextPriorAttemptsReduceCatalogAndChatBudget() async throws {
        let transport = StubTransport([
            .success(
                (
                    catalogResponse(),
                    response(
                        url: Self.apiBase.appendingPathComponent("models/user"),
                        status: 200
                    )
                )
            )
        ])
        let generator = makeGenerator(
            transport: transport,
            retryPolicy: ChatCompletionRetryPolicy(maxAttempts: 3),
            countCapabilityLookupHTTPAttempts: true
        )

        do {
            _ = try await generator.generateSQL(
                question: "Repair users query",
                schema: makeSchema(),
                context: SQLGenerationContext(mode: .repair, modelCallCount: 3),
                config: SQLGenerationConfig()
            )
            Issue.record("Expected HTTP-attempt budget exhaustion.")
        } catch let failure as HTTPAttemptBudgetExhausted {
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
            retryPolicy: ChatCompletionRetryPolicy(maxAttempts: 2),
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
        } catch let failure as CloudRequestFailure {
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
        retryPolicy: ChatCompletionRetryPolicy = ChatCompletionRetryPolicy(),
        countCapabilityLookupHTTPAttempts: Bool = false
    ) -> CloudSQLGenerator {
        let profile = CloudModelProfile.openRouterTest.requestingModel(model)
        return CloudSQLGenerator(
            apiKey: "test-key",
            profile: profile,
            transport: transport,
            capabilityResolver: CloudCapabilityResolver(
                profile: profile,
                catalogService: catalogService(transport: transport)
            ),
            retryPolicy: retryPolicy,
            countCapabilityLookupHTTPAttempts: countCapabilityLookupHTTPAttempts
        )
    }

    private func runConnectivityCheck(
        transport: StubTransport,
        expectedCanonicalModelID: String
    ) async -> OpenRouterConnectivityCheck.Result {
        await OpenRouterConnectivityCheck(
            apiKey: "test-key",
            profile: .openRouterTest.pinningReturnedModel(expectedCanonicalModelID),
            catalogService: catalogService(transport: transport),
            transport: transport
        ).run()
    }

    private func makeGenerator(transport: CancellationAwareTransport) -> CloudSQLGenerator {
        CloudSQLGenerator(
            apiKey: "test-key",
            profile: .particleTest,
            transport: transport,
            capabilityResolver: CloudCapabilityResolver(profile: .particleTest)
        )
    }

    /// A generator for `profile` whose transport answers its chat requests in
    /// order. An OpenRouter profile is first answered its catalog lookup.
    private func makeGenerator(
        profile: CloudModelProfile,
        chatResults: [Result<(Data, HTTPURLResponse), Error>],
        retryPolicy: ChatCompletionRetryPolicy = ChatCompletionRetryPolicy()
    ) -> (CloudSQLGenerator, StubTransport) {
        let catalogResults: [Result<(Data, HTTPURLResponse), Error>] =
            profile.capabilityResolution == .openRouterCatalog
            ? [.success((catalogResponse(id: profile.requestedModelID), response(url: Self.apiBase.appendingPathComponent("models/user"), status: 200)))]
            : []
        let transport = StubTransport(catalogResults + chatResults)
        let generator = CloudSQLGenerator(
            apiKey: "test-key",
            profile: profile,
            transport: transport,
            capabilityResolver: CloudCapabilityResolver(
                profile: profile,
                catalogService: catalogService(transport: transport)
            ),
            retryPolicy: retryPolicy
        )
        return (generator, transport)
    }

    private func expectProviderRequest(_ request: URLRequest, profile: CloudModelProfile) throws {
        if profile.usesOpenRouterRouting {
            try expectPrivateRouting(in: request)
        } else {
            try ParticleTestSupport.expectRequestShape(request, callSite: .oneShotSQL, profile: profile)
        }
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
            profile: .openRouterTest,
            transport: transport,
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
        model: String? = "openai/gpt-5.5",
        finishReason: String = "stop",
        refusal: String? = nil,
        choiceError: [String: Any]? = nil,
        openrouterMetadata: [String: Any]? = nil
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
        var body: [String: Any] = [
            "id": "cmpl-1",
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
        ]
        if let model {
            body["model"] = model
        }
        if let openrouterMetadata {
            body["openrouter_metadata"] = openrouterMetadata
        }
        return jsonData(body)
    }

    /// A Particle-1 completion: the `particle-ai/particle-1` model, cached and
    /// reasoning token details, and no `usage.cost` unless one is given.
    private func particleChatResponse(
        content: Any?,
        finishReason: String = "stop",
        cachedTokens: Int = 0,
        cost: Double? = nil
    ) -> Data {
        var message: [String: Any] = ["role": "assistant"]
        if let content {
            message["content"] = content
        }
        var usage: [String: Any] = [
            "prompt_tokens": 11,
            "completion_tokens": 22,
            "total_tokens": 33,
            "prompt_tokens_details": ["cached_tokens": cachedTokens],
            "completion_tokens_details": ["reasoning_tokens": 3],
        ]
        if let cost {
            usage["cost"] = cost
        }
        return jsonData([
            "id": "chatcmpl-1",
            "object": "chat.completion",
            "model": ParticleTestSupport.returnedModelID,
            "choices": [
                ["index": 0, "finish_reason": finishReason, "message": message],
            ],
            "usage": usage,
        ])
    }

    private func particleErrorResponse(code: String?, type: String?, message: String) -> Data {
        var error: [String: Any] = ["message": message]
        if let code {
            error["code"] = code
        }
        if let type {
            error["type"] = type
        }
        return jsonData(["error": error])
    }

    private func invalidModelOutputResponse() -> Data {
        particleErrorResponse(
            code: "invalid_model_output",
            type: "api_error",
            message: "The model's output was not valid JSON."
        )
    }

    private func chatResponse(for profile: CloudModelProfile, content: Any?) -> Data {
        profile.provider == .particle
            ? particleChatResponse(content: content)
            : chatResponse(content: content)
    }

    private func transientErrorResponse(for profile: CloudModelProfile) -> Data {
        profile.provider == .particle
            ? particleErrorResponse(code: "model_unavailable", type: "server_error", message: "Model unavailable.")
            : errorResponse(errorType: "provider_unavailable")
    }

    private func serverErrorResponse(for profile: CloudModelProfile) -> Data {
        profile.provider == .particle
            ? particleErrorResponse(code: "internal_error", type: "server_error", message: "Internal error.")
            : errorResponse(errorType: "server")
    }

    private func routerMetadata(
        requestedModelID: String,
        selectedModelIDs: [String]
    ) -> [String: Any] {
        [
            "requested": requestedModelID,
            "endpoints": [
                "available": selectedModelIDs.map { modelID in
                    [
                        "provider": "Azure",
                        "model": modelID,
                        "selected": true,
                    ] as [String: Any]
                },
            ],
        ]
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

    private func expectPrivateRouting(in request: URLRequest) throws {
        try OpenRouterTestSupport.expectPrivateRouting(inBody: jsonBody(request))
    }

    private func temporaryCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("openrouter-cache.json")
    }

    private func expectFailure(
        _ category: CloudRequestFailure.Category,
        operation: () throws -> CloudSQLResponseParser.ParsedResult
    ) throws {
        do {
            _ = try operation()
            Issue.record("expected \(category)")
        } catch let failure as CloudRequestFailure {
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

    private func expectCanonicalMismatch(
        service: OpenRouterModelCatalogService,
        expectedAttemptCount: Int
    ) async {
        do {
            _ = try await service.validatedCapabilitiesForGeneration(
                apiKey: "test-key",
                modelID: Self.modelID,
                expectedCanonicalModelID: "openai/gpt-5.5-20260423",
                maximumHTTPRequests: nil
            )
            Issue.record("expected canonical rollover failure")
        } catch let failure as CloudRequestFailure {
            #expect(failure.category == .modelVersionMismatch)
            #expect(failure.diagnostic.returnedModelID == "openai/gpt-5.5-20260901")
            #expect(failure.diagnostic.attemptCount == expectedAttemptCount)
        } catch {
            Issue.record("expected CloudRequestFailure, got \(error)")
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
