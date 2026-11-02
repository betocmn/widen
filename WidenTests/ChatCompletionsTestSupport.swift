import Foundation
import Testing

@testable import WidenKit

extension CloudModelProfile {
    /// The Particle-1 production profile pointed at a `particle.test` host.
    /// Like production, it pins the returned model to `particle-ai/particle-1`.
    static let particleTest: CloudModelProfile = {
        var profile = CloudModelProfile.particle
        profile.baseURL = URL(string: "https://particle.test/v1")!
        return profile
    }()

    /// The OpenRouter eval profile pointed at an `openrouter.test` host. The
    /// returned model is left unpinned, as these suites always ran; tests of
    /// canonical-version pinning set it with `pinningReturnedModel(_:)`.
    static let openRouterTest: CloudModelProfile = {
        var profile = CloudModelProfile.openRouterGPT55
        profile.baseURL = URL(string: "https://openrouter.test/api/v1")!
        profile.expectedReturnedModelID = nil
        return profile
    }()

    func pinningReturnedModel(_ modelID: String?) -> CloudModelProfile {
        var copy = self
        copy.expectedReturnedModelID = modelID
        return copy
    }

    func requestingModel(_ modelID: String) -> CloudModelProfile {
        var copy = self
        copy.requestedModelID = modelID
        return copy
    }
}

extension CloudModelProfile: CustomTestStringConvertible {
    public var testDescription: String {
        "\(provider.rawValue) \(requestedModelID) at \(baseURL.host ?? "?")"
    }
}

/// Records every request before answering it from a handler, so a test can
/// assert exactly what would have been sent and to which host.
final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Int) throws -> (Data, HTTPURLResponse)

    private let lock = NSLock()
    private let handler: Handler
    private var recorded: [URLRequest] = []

    init(_ handler: @escaping Handler = { _, _ in throw URLError(.badServerResponse) }) {
        self.handler = handler
    }

    var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = lock.withLock {
            recorded.append(request)
            return recorded.count
        }
        return try handler(request, index)
    }

    static func response(
        to request: URLRequest,
        status: Int = 200,
        headers: [String: String] = [:]
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"].merging(headers) { _, new in new }
        )!
    }
}

enum ParticleTestSupport {
    static let returnedModelID = "particle-ai/particle-1"

    /// A trimmed copy of the live `GET /v1/models` entry (schema 2.4), which
    /// nests limits and parameters under the text modalities instead of the
    /// documented flat fields. `serviceTier` marks the alternate-tier listing.
    static func nestedParticleModel(
        serviceTier: String? = nil,
        contextLength: Int = 1_048_576,
        listsTools: Bool = true
    ) -> [String: Any] {
        var parameters: [String: Any] = [
            "max_tokens": ["type": "integer", "min": 1, "max": 131_072],
            "reasoning_effort": [
                "type": "enum",
                "values": ["high", "low", "max", "medium", "minimal", "none", "ultra", "xhigh"],
            ],
        ]
        if listsTools {
            parameters["tools"] = ["type": "boolean"]
            parameters["tool_choice"] = ["type": "unknown"]
        }
        var model: [String: Any] = [
            "schema_version": "2.4",
            "id": ParticleTestSupport.returnedModelID,
            "name": "Particle-1",
            "is_ready": true,
            "input_modalities": [
                [
                    "type": "text",
                    "supported_inputs": ["max_context_length": ["value": contextLength, "unit": "token"]],
                ],
                ["type": "image"],
            ],
            "output_modalities": [
                [
                    "type": "text",
                    "max_length": ["value": 131_072, "unit": "token"],
                    "supported_parameters": parameters,
                ]
            ],
        ]
        if let serviceTier {
            model["service_tier"] = serviceTier
        }
        return model
    }

    /// Asserts a chat request carries only what Particle-1 should receive for
    /// a call site, and returns its body. Never sent: OpenRouter's provider
    /// block and X-* headers, `temperature`, `max_tokens`, `n`, `seed`, or a
    /// tool-message `name`.
    @discardableResult
    static func expectRequestShape(
        _ request: URLRequest,
        callSite: CloudCallSite,
        profile: CloudModelProfile = .particleTest,
        requiresPromptCacheKey: Bool = true
    ) throws -> [String: Any] {
        let policy = profile.policy(for: callSite)
        let headers = request.allHTTPHeaderFields ?? [:]
        #expect(request.url == profile.chatCompletionsURL)
        #expect(request.httpMethod == "POST")
        #expect(headers["Authorization"]?.hasPrefix("Bearer ") == true)
        #expect(headers["Content-Type"] == "application/json")
        #expect(!headers.keys.contains { $0.lowercased().hasPrefix("x-") })

        let body = try requestBody(request)
        #expect(body["model"] as? String == "particle-1")
        #expect(body["stream"] as? Bool == false)
        #expect(body["max_completion_tokens"] as? Int == policy.maxCompletionTokens)
        #expect(body["reasoning_effort"] as? String == policy.reasoningEffort?.rawValue)
        for key in ["provider", "temperature", "max_tokens", "n", "seed"] {
            #expect(body[key] == nil, "Particle request must not send \(key)")
        }
        if requiresPromptCacheKey {
            let cacheKey = try #require(body["prompt_cache_key"] as? String)
            #expect(cacheKey.hasPrefix("widen-"))
            #expect(cacheKey.utf8.count <= 256)
        } else {
            #expect(body["prompt_cache_key"] == nil)
        }

        switch callSite {
        case .agentTurn:
            #expect(body["tools"] is [Any])
            #expect(body["tool_choice"] as? String == "required")
            #expect(body["parallel_tool_calls"] as? Bool == true)
            #expect(body["response_format"] == nil)
            let messages = try #require(body["messages"] as? [[String: Any]])
            #expect(messages.allSatisfy { $0["name"] == nil })
        case .oneShotSQL, .connectivityProbe, .sessionTitle, .critic:
            #expect(body["tools"] == nil)
            #expect(body["tool_choice"] == nil)
            #expect(body["parallel_tool_calls"] == nil)
            let format = body["response_format"] as? [String: Any]
            #expect(
                format?["type"] as? String
                    == (policy.responseFormat == .jsonObject ? "json_object" : nil)
            )
        }
        return body
    }

    static func promptCacheKey(in request: URLRequest) throws -> String? {
        try requestBody(request)["prompt_cache_key"] as? String
    }

    private static func requestBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

enum OpenRouterTestSupport {
    /// Asserts a request body carries exactly the production private-routing
    /// provider preferences, derived from the production constants so every
    /// suite tracks future changes to the required private routing block.
    static func expectPrivateRouting(inBody body: [String: Any]) throws {
        let provider = try #require(body["provider"] as? [String: Any])
        #expect(
            provider["require_parameters"] as? Bool
                == OpenRouterProviderPreferences.requireParameters
        )
        #expect(provider["zdr"] as? Bool == OpenRouterProviderPreferences.zdr)
        #expect(
            provider["data_collection"] as? String
                == OpenRouterProviderPreferences.dataCollection
        )
        #expect(provider.count == 3)
    }
}
