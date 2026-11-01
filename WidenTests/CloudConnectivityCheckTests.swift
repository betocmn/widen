import Foundation
import Testing

@testable import WidenKit

@Suite("Cloud connectivity check")
struct CloudConnectivityCheckTests {
    private struct Reply: Sendable {
        var status = 200
        var body: Data
        var headers: [String: String] = [:]
    }

    @Test func listsTheModelThenVerifiesOneTinyCompletion() async throws {
        let profile = CloudModelProfile.particleTest
        let transport = Self.scripted([
            Reply(body: Self.modelList([Self.particleModel()])),
            Reply(body: Self.pingResponse()),
        ])

        let result = await CloudConnectivityCheck(
            apiKey: "pai-test",
            profile: profile,
            transport: transport
        ).run()

        #expect(result.error == nil)
        #expect(result.keyAccepted)
        #expect(result.modelListed)
        #expect(result.toolCallingAdvertised == true)
        #expect(result.contextWindowTokens == 1_048_576)
        #expect(result.defaultReasoningEffort == "high")
        #expect(result.returnedModelID == ParticleTestSupport.returnedModelID)
        #expect(result.completionVerified)
        #expect(result.latencyMs >= 0)

        let requests = transport.requests
        try #require(requests.count == 2)
        #expect(requests[0].url == profile.modelsURL)
        #expect(requests[0].httpMethod == "GET")
        #expect(requests[0].httpBody == nil)
        #expect(requests[0].allHTTPHeaderFields == ["Authorization": "Bearer pai-test"])
        let body = try ParticleTestSupport.expectRequestShape(
            requests[1],
            callSite: .connectivityProbe,
            profile: profile,
            requiresPromptCacheKey: false
        )
        #expect(body["reasoning_effort"] as? String == "none")
        #expect(body["max_completion_tokens"] as? Int == 256)
        #expect((body["response_format"] as? [String: Any])?["type"] as? String == "json_object")
        Self.expectProfileHost(requests, profile: profile)
    }

    @Test func modelListDecodesBareArraysAndToleratesUnexpectedFields() async throws {
        let transport = Self.scripted([
            Reply(body: Self.jsonData([
                ["id": 7],
                [
                    "id": ParticleTestSupport.returnedModelID,
                    "context_window": "large",
                    "capabilities": ["tool_calling": "yes"],
                    "reasoning": "high",
                    "pricing": ["input": 0.25],
                ],
            ] as [[String: Any]]))
        ])

        let result = await CloudConnectivityCheck(
            apiKey: "pai-test",
            profile: .particleTest,
            transport: transport,
            includeCompletion: false
        ).run()

        #expect(result.error == nil)
        #expect(result.keyAccepted)
        #expect(result.modelListed)
        #expect(result.toolCallingAdvertised == nil)
        #expect(result.contextWindowTokens == nil)
        #expect(result.defaultReasoningEffort == nil)
        #expect(!result.completionVerified)
        #expect(result.returnedModelID == nil)
        #expect(transport.requests.count == 1)
    }

    @Test func rejectedKeyIsNotAccepted() async throws {
        let rejected = Reply(
            status: 401,
            body: Self.errorBody(
                code: "invalid_bearer_credential",
                type: "authentication_error",
                message: "Invalid bearer credential."
            )
        )
        let listTransport = Self.scripted([rejected])

        let listResult = await CloudConnectivityCheck(
            apiKey: "pai-test",
            profile: .particleTest,
            transport: listTransport
        ).run()

        #expect(!listResult.keyAccepted)
        #expect(!listResult.modelListed)
        #expect(!listResult.completionVerified)
        #expect(listResult.error?.category == .authentication)
        #expect(listResult.error?.diagnostic.httpStatus == 401)
        #expect(listResult.error?.diagnostic.providerCode == "invalid_bearer_credential")
        #expect(listTransport.requests.count == 1)

        // A key rejected only by the completion is not accepted either.
        let completionTransport = Self.scripted([
            Reply(body: Self.modelList([Self.particleModel()])),
            rejected,
        ])
        let completionResult = await CloudConnectivityCheck(
            apiKey: "pai-test",
            profile: .particleTest,
            transport: completionTransport
        ).run()

        #expect(!completionResult.keyAccepted)
        #expect(completionResult.modelListed)
        #expect(!completionResult.completionVerified)
        #expect(completionResult.error?.category == .authentication)
        #expect(completionTransport.requests.count == 2)
    }

    @Test func missingModelFailsBeforeAnyCompletion() async throws {
        let transport = Self.scripted([
            Reply(body: Self.modelList([
                Self.particleModel(id: "particle-0"),
                Self.particleModel(id: "other/particle-1"),
            ]))
        ])

        let result = await CloudConnectivityCheck(
            apiKey: "pai-test",
            profile: .particleTest,
            transport: transport
        ).run()

        #expect(result.keyAccepted)
        #expect(!result.modelListed)
        #expect(!result.completionVerified)
        #expect(result.error?.category == .modelNotFound)
        #expect(result.error?.message.contains("Particle-1") == true)
        #expect(transport.requests.map(\.httpMethod) == ["GET"])
    }

    @Test func modelWithoutToolCallingFailsBeforeAnyCompletion() async throws {
        let transport = Self.scripted([
            Reply(body: Self.modelList([Self.particleModel(toolCalling: false)]))
        ])

        let result = await CloudConnectivityCheck(
            apiKey: "pai-test",
            profile: .particleTest,
            transport: transport
        ).run()

        #expect(result.keyAccepted)
        #expect(result.modelListed)
        #expect(result.toolCallingAdvertised == false)
        #expect(result.contextWindowTokens == 1_048_576)
        #expect(!result.completionVerified)
        #expect(result.error?.category == .unsupportedFeature)
        #expect(result.error?.message.contains("tool calling") == true)
        #expect(transport.requests.map(\.httpMethod) == ["GET"])
    }

    /// The check runs before any connection is chosen, so neither request
    /// may carry schema, database context or a question.
    @Test func payloadCarriesNoSchemaDatabaseContextOrQuestion() async throws {
        let transport = Self.scripted([
            Reply(body: Self.modelList([Self.particleModel()])),
            Reply(body: Self.pingResponse()),
        ])

        _ = await CloudConnectivityCheck(
            apiKey: "pai-test",
            profile: .particleTest,
            transport: transport
        ).run()

        let requests = transport.requests
        try #require(requests.count == 2)
        #expect(requests[0].httpBody == nil)
        #expect(requests[0].url?.query == nil)
        let body = try Self.jsonBody(requests[1])
        #expect(
            Set(body.keys) == [
                "model", "messages", "stream", "max_completion_tokens", "response_format",
                "reasoning_effort",
            ]
        )
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(
            messages == [
                ["role": "system", "content": #"Reply with {"ok":true}"#],
                ["role": "user", "content": "ping"],
            ]
        )
        let sent = String(decoding: try #require(requests[1].httpBody), as: UTF8.self)
        for forbidden in ["TABLE", "SELECT", "Database context", "SQL history", "public.users", "\"sql\""] {
            #expect(!sent.contains(forbidden), "connectivity payload must not contain \(forbidden)")
        }
    }

    @Test(arguments: ["particle-ai/particle-2", nil] as [String?])
    func returnedModelMismatchFailsVerification(returnedModelID: String?) async throws {
        let transport = Self.scripted([
            Reply(body: Self.modelList([Self.particleModel()])),
            Reply(body: Self.pingResponse(model: returnedModelID)),
        ])

        let result = await CloudConnectivityCheck(
            apiKey: "pai-test",
            profile: .particleTest,
            transport: transport
        ).run()

        #expect(result.keyAccepted)
        #expect(result.modelListed)
        #expect(!result.completionVerified)
        #expect(result.returnedModelID == returnedModelID)
        #expect(result.error?.category == .modelVersionMismatch)
        // An identity mismatch is not retried.
        #expect(transport.requests.count == 2)
    }

    @Test func replyThatIsNotAJSONObjectIsNotVerified() async throws {
        let transport = Self.scripted([
            Reply(body: Self.modelList([Self.particleModel()])),
            Reply(body: Self.pingResponse(content: "ok")),
        ])

        let result = await CloudConnectivityCheck(
            apiKey: "pai-test",
            profile: .particleTest,
            transport: transport
        ).run()

        #expect(!result.completionVerified)
        #expect(result.returnedModelID == ParticleTestSupport.returnedModelID)
        #expect(result.error?.category == .malformedStructuredResponse)
        #expect(transport.requests.count == 2)
    }

    @Test func everyRequestGoesOnlyToTheParticleHost() async throws {
        let profile = CloudModelProfile.particle
        let transport = Self.scripted([
            Reply(body: Self.modelList([Self.particleModel()])),
            Reply(body: Self.pingResponse()),
        ])

        let result = await CloudConnectivityCheck(apiKey: "pai-test", transport: transport).run()

        #expect(result.error == nil)
        let requests = transport.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.url?.scheme == "https" })
        #expect(requests.allSatisfy { $0.url?.host == "api.particle.ai" })
        Self.expectProfileHost(requests, profile: profile)
        #expect(requests.map { $0.url?.path } == ["/v1/models", "/v1/chat/completions"])

        // The default is the Particle profile over a 30-second transport.
        let check = CloudConnectivityCheck(apiKey: "pai-test")
        #expect(check.profile == .particle)
        let defaultTransport = try #require(check.transport as? URLSessionTransport)
        #expect(defaultTransport.sessionConfiguration.timeoutIntervalForRequest == 30)

        // An OpenRouter key is refused before anything is sent.
        let foreignKeyTransport = RecordingTransport()
        let foreignKeyResult = await CloudConnectivityCheck(
            apiKey: "sk-or-v1-abc",
            transport: foreignKeyTransport
        ).run()
        #expect(foreignKeyResult.error?.category == .invalidRequest)
        #expect(foreignKeyResult.error?.message.lowercased().contains("credential host mismatch") == true)
        #expect(!foreignKeyResult.keyAccepted)
        #expect(foreignKeyTransport.requests.isEmpty)

        // A profile without a model list sends nothing.
        let openRouterTransport = RecordingTransport()
        let openRouterResult = await CloudConnectivityCheck(
            apiKey: "test-key",
            profile: .openRouterTest,
            transport: openRouterTransport
        ).run()
        #expect(openRouterResult.error?.category == .unsupportedFeature)
        #expect(openRouterTransport.requests.isEmpty)
    }

    @Test func rateLimitedRequestsAreRetriedOnce() async throws {
        let rateLimited = Reply(
            status: 429,
            body: Self.errorBody(
                code: "fleet_capacity_exhausted",
                type: "rate_limit_error",
                message: "Fleet capacity exhausted."
            ),
            headers: ["Retry-After": "0"]
        )
        let transport = Self.scripted([
            rateLimited,
            Reply(body: Self.modelList([Self.particleModel()])),
            rateLimited,
            Reply(body: Self.pingResponse()),
        ])

        let result = await CloudConnectivityCheck(
            apiKey: "pai-test",
            profile: .particleTest,
            transport: transport
        ).run()

        #expect(result.error == nil)
        #expect(result.keyAccepted)
        #expect(result.completionVerified)
        #expect(
            transport.requests.map { $0.url?.path } == [
                "/v1/models", "/v1/models", "/v1/chat/completions", "/v1/chat/completions",
            ]
        )
        Self.expectProfileHost(transport.requests, profile: .particleTest)

        // A second rate limit ends the check: at most two attempts each.
        let exhaustedTransport = Self.scripted([
            Reply(body: Self.modelList([Self.particleModel()])),
            rateLimited,
            rateLimited,
        ])
        let exhausted = await CloudConnectivityCheck(
            apiKey: "pai-test",
            profile: .particleTest,
            transport: exhaustedTransport
        ).run()

        #expect(exhausted.keyAccepted)
        #expect(!exhausted.completionVerified)
        #expect(exhausted.error?.category == .rateLimited)
        #expect(exhausted.error?.diagnostic.attemptCount == 2)
        #expect(exhaustedTransport.requests.count == 3)
    }

    // MARK: - Helpers

    private static func scripted(_ replies: [Reply]) -> RecordingTransport {
        RecordingTransport { request, index in
            guard index <= replies.count else { throw URLError(.badServerResponse) }
            let reply = replies[index - 1]
            return (
                reply.body,
                RecordingTransport.response(to: request, status: reply.status, headers: reply.headers)
            )
        }
    }

    private static func expectProfileHost(_ requests: [URLRequest], profile: CloudModelProfile) {
        for request in requests {
            #expect(request.url?.host == profile.baseURL.host)
        }
    }

    private static func particleModel(
        id: String = "particle-1",
        toolCalling: Bool = true
    ) -> [String: Any] {
        [
            "id": id,
            "object": "model",
            "owned_by": "particle-ai",
            "context_window": 1_048_576,
            "max_output_tokens": 131_072,
            "capabilities": ["tool_calling": toolCalling, "structured_outputs": false],
            "reasoning": [
                "default_effort": "high",
                "supported_efforts": ["none", "low", "medium", "high"],
            ],
        ]
    }

    private static func modelList(_ models: [[String: Any]]) -> Data {
        jsonData(["object": "list", "data": models])
    }

    private static func pingResponse(
        model: String? = ParticleTestSupport.returnedModelID,
        content: String = #"{"ok":true}"#
    ) -> Data {
        var response: [String: Any] = [
            "id": "chatcmpl-ping",
            "object": "chat.completion",
            "choices": [
                [
                    "index": 0,
                    "finish_reason": "stop",
                    "message": ["role": "assistant", "content": content],
                ]
            ],
            "usage": [
                "prompt_tokens": 12,
                "completion_tokens": 4,
                "total_tokens": 16,
                "prompt_tokens_details": ["cached_tokens": 0],
            ],
        ]
        if let model {
            response["model"] = model
        }
        return jsonData(response)
    }

    private static func errorBody(code: String, type: String, message: String) -> Data {
        jsonData(["error": ["message": message, "type": type, "code": code]])
    }

    private static func jsonData(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private static func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
