import Foundation

/// The provider a cloud model profile sends its requests to.
public enum CloudModelProviderID: String, Codable, CaseIterable, Sendable {
    case particle
    case openRouter
}

/// The `reasoning_effort` values an OpenAI-compatible provider may accept.
public enum ReasoningEffort: String, Codable, CaseIterable, Sendable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra
}

/// The places Widen sends a chat completion from. Each one has its own
/// reasoning, token and response-format policy in a profile.
public enum CloudCallSite: String, CaseIterable, Sendable {
    case agentTurn
    case oneShotSQL
    case connectivityProbe
    case sessionTitle
}

public enum CloudResponseFormat: Equatable, Sendable {
    /// Send no `response_format`.
    case none
    /// Send `{"type":"json_object"}`. The provider checks JSON syntax only,
    /// so the answer is still validated locally.
    case jsonObject
    /// Send the strict SQL JSON schema, but only when the model's
    /// capabilities advertise structured outputs.
    case strictJSONSchemaWhenAdvertised
}

public struct CloudCallSitePolicy: Equatable, Sendable {
    /// `nil` omits `reasoning_effort` and leaves the provider default.
    public var reasoningEffort: ReasoningEffort?
    public var maxCompletionTokens: Int
    public var responseFormat: CloudResponseFormat

    public init(
        reasoningEffort: ReasoningEffort?,
        maxCompletionTokens: Int,
        responseFormat: CloudResponseFormat
    ) {
        self.reasoningEffort = reasoningEffort
        self.maxCompletionTokens = maxCompletionTokens
        self.responseFormat = responseFormat
    }

    /// Used for a call site a profile does not configure: the provider's
    /// default effort, the long-standing 2,048-token cap and no format.
    public static let unconfigured = CloudCallSitePolicy(
        reasoningEffort: nil,
        maxCompletionTokens: 2_048,
        responseFormat: .none
    )
}

/// List prices in USD per 1M tokens.
public struct CloudModelPricing: Equatable, Sendable {
    public var input: Double
    public var cachedInput: Double
    public var output: Double

    public init(input: Double, cachedInput: Double, output: Double) {
        self.input = input
        self.cachedInput = cachedInput
        self.output = output
    }
}

public enum CloudCapabilityResolution: Equatable, Sendable {
    /// Capabilities fixed in the profile; resolving them sends no request.
    case staticCapabilities(CloudModelCapabilities)
    /// Capabilities read from the authenticated OpenRouter catalog (evals only).
    case openRouterCatalog
}

public enum CloudModelIdentityPolicy: Equatable, Sendable {
    /// The response must name exactly the expected returned model.
    case exactReturnedModelID
    /// OpenRouter's canonical dated version, cross-checked with router metadata.
    case openRouterCanonical
}

/// Everything Widen needs to talk to one model at one provider: where to
/// send requests, which parameters to send, and which API keys it may sign.
public struct CloudModelProfile: Equatable, Sendable {
    public internal(set) var provider: CloudModelProviderID
    public internal(set) var displayName: String
    public internal(set) var baseURL: URL
    public internal(set) var chatCompletionsPath: String
    public internal(set) var modelsPath: String?
    public internal(set) var requestedModelID: String
    public internal(set) var expectedReturnedModelID: String?
    public internal(set) var identityPolicy: CloudModelIdentityPolicy
    public internal(set) var capabilityResolution: CloudCapabilityResolution
    public internal(set) var pricing: CloudModelPricing?
    public internal(set) var reportsUsageCost: Bool
    public internal(set) var callSites: [CloudCallSite: CloudCallSitePolicy]
    /// `nil` omits `parallel_tool_calls`.
    public internal(set) var parallelToolCalls: Bool?
    public internal(set) var usesPromptCacheKey: Bool
    public internal(set) var echoesReasoningContent: Bool
    public internal(set) var sendsToolMessageName: Bool
    /// OpenRouter's provider block, X-Title and X-OpenRouter-Metadata headers,
    /// routing-message heuristics and catalog invalidation.
    public internal(set) var usesOpenRouterRouting: Bool
    public internal(set) var errorCodeCategories: [String: CloudRequestFailure.Category]
    public internal(set) var errorTypeCategories: [String: CloudRequestFailure.Category]
    public internal(set) var requestIDHeaderNames: [String]
    public internal(set) var requestTimeoutSeconds: TimeInterval
    /// `nil` keeps URLSession's default resource timeout.
    public internal(set) var resourceTimeoutSeconds: TimeInterval?
    /// Key prefixes that belong to other providers and must never be sent here.
    public internal(set) var foreignAPIKeyPrefixes: [String]
    public internal(set) var evalAPIKeyEnvironmentVariable: String

    public func policy(for callSite: CloudCallSite) -> CloudCallSitePolicy {
        callSites[callSite] ?? .unconfigured
    }

    /// One `prompt_cache_key` per generation run, shared by every request in
    /// that run. It holds no user data and stays well under 256 bytes.
    func makePromptCacheKey() -> String? {
        usesPromptCacheKey ? "widen-" + UUID().uuidString.lowercased() : nil
    }

    var chatCompletionsURL: URL {
        baseURL.appendingPathComponent(chatCompletionsPath)
    }

    var modelsURL: URL? {
        modelsPath.map { baseURL.appendingPathComponent($0) }
    }

    /// Builds a request that carries the API key. This is the only code that
    /// sets `Authorization`, so it refuses, before anything is sent, a URL
    /// that is not https on this profile's host and port, and a key that
    /// belongs to another provider.
    func authorizedRequest(
        _ url: URL,
        apiKey: String,
        httpMethod: String = "POST"
    ) throws -> URLRequest {
        let host = baseURL.host?.lowercased()
        guard url.scheme?.lowercased() == "https",
            host != nil,
            url.host?.lowercased() == host,
            url.port == baseURL.port
        else {
            throw CloudRequestFailure(
                category: .invalidRequest,
                message: "Credential host mismatch: Widen sends the \(displayName) API key only to https://\(host ?? "its provider host").",
                requestedModelID: requestedModelID,
                attemptCount: 0
            )
        }
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !foreignAPIKeyPrefixes.contains(where: { normalizedKey.hasPrefix($0.lowercased()) })
        else {
            throw CloudRequestFailure(
                category: .invalidRequest,
                message: "Credential host mismatch: this API key belongs to another provider, so Widen will not send it to \(displayName).",
                requestedModelID: requestedModelID,
                attemptCount: 0
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = httpMethod
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let sendsBody = httpMethod == "POST"
        if sendsBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if usesOpenRouterRouting {
            request.setValue("Widen", forHTTPHeaderField: "X-Title")
            if sendsBody {
                request.setValue("enabled", forHTTPHeaderField: "X-OpenRouter-Metadata")
            }
        }
        return request
    }
}

extension CloudModelProfile {
    /// Particle-1 at particle.ai. Its capabilities are fixed here, so no
    /// catalog request is ever made with a Particle key. Prices are peak list
    /// prices, so cost estimates from them are an upper bound.
    public static let particle = CloudModelProfile(
        provider: .particle,
        displayName: "Particle-1",
        baseURL: URL(string: "https://api.particle.ai/v1")!,
        chatCompletionsPath: "chat/completions",
        modelsPath: "models",
        requestedModelID: "particle-1",
        expectedReturnedModelID: "particle-ai/particle-1",
        identityPolicy: .exactReturnedModelID,
        capabilityResolution: .staticCapabilities(
            CloudModelCapabilities(
                supportsResponseFormat: true,
                supportsStructuredOutputs: false,
                supportsTools: true,
                supportsToolChoice: true,
                supportsTemperature: false,
                supportsSeed: false,
                supportsMaxTokens: false,
                supportsMaxCompletionTokens: true,
                contextLength: 1_048_576,
                maximumCompletionTokens: 131_072,
                capabilitySource: .staticProfile,
                fetchedAt: Date(timeIntervalSince1970: 0)
            )
        ),
        pricing: CloudModelPricing(input: 0.25, cachedInput: 0.03, output: 1.00),
        reportsUsageCost: false,
        callSites: [
            .agentTurn: CloudCallSitePolicy(
                reasoningEffort: .high,
                maxCompletionTokens: 16_000,
                responseFormat: .none
            ),
            .oneShotSQL: CloudCallSitePolicy(
                reasoningEffort: .high,
                maxCompletionTokens: 16_000,
                responseFormat: .jsonObject
            ),
            .connectivityProbe: CloudCallSitePolicy(
                reasoningEffort: ReasoningEffort.none,
                maxCompletionTokens: 256,
                responseFormat: .jsonObject
            ),
            .sessionTitle: CloudCallSitePolicy(
                reasoningEffort: ReasoningEffort.none,
                maxCompletionTokens: 64,
                responseFormat: .none
            ),
        ],
        parallelToolCalls: true,
        usesPromptCacheKey: true,
        echoesReasoningContent: false,
        sendsToolMessageName: false,
        usesOpenRouterRouting: false,
        errorCodeCategories: [:],
        errorTypeCategories: [:],
        requestIDHeaderNames: ["X-Request-Id", "Request-Id"],
        requestTimeoutSeconds: 180,
        resourceTimeoutSeconds: 300,
        foreignAPIKeyPrefixes: ["sk-or-"],
        evalAPIKeyEnvironmentVariable: "WIDEN_EVAL_PARTICLE_API_KEY"
    )

    /// GPT-5.5 through OpenRouter, the previous production model. Evals keep
    /// it to compare against; it sends the same requests the app sent before.
    public static let openRouterGPT55 = openRouter(
        requestedModelID: "openai/gpt-5.5",
        expectedReturnedModelID: "openai/gpt-5.5-20260423",
        displayName: "GPT-5.5"
    )

    /// An OpenRouter model for eval comparisons. Its capabilities come from
    /// the authenticated OpenRouter catalog.
    public static func openRouter(
        requestedModelID: String,
        expectedReturnedModelID: String?,
        displayName: String? = nil
    ) -> CloudModelProfile {
        let oneShot = CloudCallSitePolicy(
            reasoningEffort: nil,
            maxCompletionTokens: 2_048,
            responseFormat: .strictJSONSchemaWhenAdvertised
        )
        return CloudModelProfile(
            provider: .openRouter,
            displayName: displayName ?? requestedModelID,
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            chatCompletionsPath: "chat/completions",
            modelsPath: nil,
            requestedModelID: requestedModelID,
            expectedReturnedModelID: expectedReturnedModelID,
            identityPolicy: .openRouterCanonical,
            capabilityResolution: .openRouterCatalog,
            pricing: nil,
            reportsUsageCost: true,
            callSites: [
                .agentTurn: CloudCallSitePolicy(
                    reasoningEffort: nil,
                    maxCompletionTokens: 2_048,
                    responseFormat: .none
                ),
                .oneShotSQL: oneShot,
                .connectivityProbe: oneShot,
            ],
            parallelToolCalls: nil,
            usesPromptCacheKey: false,
            echoesReasoningContent: false,
            sendsToolMessageName: true,
            usesOpenRouterRouting: true,
            errorCodeCategories: [:],
            errorTypeCategories: [:],
            requestIDHeaderNames: ["X-Request-Id", "X-Generation-Id"],
            requestTimeoutSeconds: 90,
            resourceTimeoutSeconds: nil,
            foreignAPIKeyPrefixes: ["pai-"],
            evalAPIKeyEnvironmentVariable: "WIDEN_EVAL_OPENROUTER_API_KEY"
        )
    }
}

extension URLSessionTransport {
    /// A transport with the profile's request and resource timeouts.
    init(timeoutsOf profile: CloudModelProfile) {
        self.init(
            timeout: profile.requestTimeoutSeconds,
            resourceTimeout: profile.resourceTimeoutSeconds
        )
    }
}

/// The fixed cloud production profile. Changing either model ID requires
/// a new release-gate evaluation and an app update.
public enum CloudModelCatalog {
    public static let productionProfile: CloudModelProfile = .openRouterGPT55

    /// The returned model version to enforce for a requested model ID. Evals
    /// may run arbitrary models, but when they run the pinned production model
    /// they must enforce the same returned-version contract as the app.
    public static func expectedReturnedModelID(forRequestedModelID id: String) -> String? {
        id == productionProfile.requestedModelID
            ? productionProfile.expectedReturnedModelID
            : nil
    }
}
