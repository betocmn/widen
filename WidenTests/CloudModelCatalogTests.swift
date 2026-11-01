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
        #expect(profile.requestIDHeaderNames == ["X-Request-Id", "Request-Id"])
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
            tools: [],
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
        try OpenRouterTestSupport.expectPrivateRouting(inBody: body)
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

    @Test func releaseGateModelPolicyRejectsUnpinnedDocPublishingRuns() {
        let pinned = CloudModelCatalog.productionProfile.requestedModelID
        #expect(throws: Never.self) {
            try TextToSQLReleaseGateModelPolicy.validate(
                model: pinned,
                backendIncludesCloud: true,
                releaseGateVersion: "0.1.0",
                releaseTriageVersion: nil,
                allowModelOverride: false
            )
        }
        #expect(throws: TextToSQLReleaseGateModelPolicy.Violation.self) {
            try TextToSQLReleaseGateModelPolicy.validate(
                model: "vendor/other",
                backendIncludesCloud: true,
                releaseGateVersion: "0.1.0",
                releaseTriageVersion: nil,
                allowModelOverride: false
            )
        }
        #expect(throws: TextToSQLReleaseGateModelPolicy.Violation.self) {
            try TextToSQLReleaseGateModelPolicy.validate(
                model: "vendor/other",
                backendIncludesCloud: true,
                releaseGateVersion: nil,
                releaseTriageVersion: "0.1.0",
                allowModelOverride: false
            )
        }
        #expect(throws: Never.self) {
            try TextToSQLReleaseGateModelPolicy.validate(
                model: "vendor/other",
                backendIncludesCloud: true,
                releaseGateVersion: "0.1.0",
                releaseTriageVersion: nil,
                allowModelOverride: true
            )
        }
        #expect(throws: Never.self) {
            try TextToSQLReleaseGateModelPolicy.validate(
                model: "vendor/other",
                backendIncludesCloud: true,
                releaseGateVersion: nil,
                releaseTriageVersion: nil,
                allowModelOverride: false
            )
        }
        #expect(throws: TextToSQLReleaseGateModelPolicy.Violation.self) {
            try TextToSQLReleaseGateModelPolicy.validate(
                model: pinned,
                backendIncludesCloud: false,
                releaseGateVersion: "0.1.0",
                releaseTriageVersion: nil,
                allowModelOverride: false
            )
        }
        #expect(throws: Never.self) {
            try TextToSQLReleaseGateModelPolicy.validate(
                model: pinned,
                backendIncludesCloud: false,
                releaseGateVersion: "0.1.0",
                releaseTriageVersion: nil,
                allowModelOverride: true
            )
        }
    }

    @Test func releaseArtifactVersionsCannotEscapeTheirOutputDirectory() {
        for version in ["0.1.0", "1.0-beta_1"] {
            #expect(throws: Never.self) {
                try TextToSQLReleaseArtifactVersionPolicy.validate(version)
            }
        }

        let invalidVersions = [
            "",
            "../README",
            "0.1/../../README",
            ".hidden",
            "version with spaces",
            "v\u{00E9}rsion",
            String(repeating: "a", count: 65),
        ]
        for version in invalidVersions {
            #expect(throws: TextToSQLReleaseArtifactVersionPolicy.Violation.self) {
                try TextToSQLReleaseArtifactVersionPolicy.validate(version)
            }
        }

        #expect(throws: TextToSQLReleaseArtifactVersionPolicy.Violation.self) {
            try TextToSQLReleaseGateModelPolicy.validate(
                model: "vendor/other",
                backendIncludesCloud: true,
                releaseGateVersion: "../README",
                releaseTriageVersion: nil,
                allowModelOverride: true
            )
        }
    }

    @Test func committedDocEligibilityRequiresVerifiedCloudEvaluation() {
        let profile = CloudModelCatalog.productionProfile
        let effort = profile.policy(for: .agentTurn).reasoningEffort?.rawValue
        #expect(
            TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: profile.requestedModelID,
                expectedReturnedModelID: profile.expectedReturnedModelID,
                reasoningEffort: effort,
                callSite: .agentTurn,
                backendIncludesCloud: true,
                cloudEvaluatedResultCount: 1
            )
        )
        #expect(
            !TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: nil,
                expectedReturnedModelID: profile.expectedReturnedModelID,
                reasoningEffort: effort,
                callSite: .agentTurn,
                backendIncludesCloud: true,
                cloudEvaluatedResultCount: 1
            )
        )
        #expect(
            !TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: profile.requestedModelID,
                expectedReturnedModelID: profile.expectedReturnedModelID,
                reasoningEffort: effort,
                callSite: .agentTurn,
                backendIncludesCloud: false,
                cloudEvaluatedResultCount: 1
            )
        )
        #expect(
            !TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: "vendor/other",
                expectedReturnedModelID: profile.expectedReturnedModelID,
                reasoningEffort: effort,
                callSite: .agentTurn,
                backendIncludesCloud: true,
                cloudEvaluatedResultCount: 1
            )
        )
        #expect(
            !TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: profile.requestedModelID,
                expectedReturnedModelID: nil,
                reasoningEffort: effort,
                callSite: .agentTurn,
                backendIncludesCloud: true,
                cloudEvaluatedResultCount: 1
            )
        )
        #expect(
            !TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: profile.requestedModelID,
                expectedReturnedModelID: "openai/gpt-5.5-unevaluated",
                reasoningEffort: effort,
                callSite: .agentTurn,
                backendIncludesCloud: true,
                cloudEvaluatedResultCount: 1
            )
        )
        #expect(
            !TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: profile.requestedModelID,
                expectedReturnedModelID: profile.expectedReturnedModelID,
                reasoningEffort: effort,
                callSite: .agentTurn,
                backendIncludesCloud: true,
                cloudEvaluatedResultCount: 0
            )
        )
    }

    @Test func committedDocIneligibilityExplainsMissingExecutionEvidence() {
        let profile = CloudModelCatalog.productionProfile
        let effort = profile.policy(for: .agentTurn).reasoningEffort?.rawValue
        let reason = TextToSQLReleaseGateModelPolicy.committedDocIneligibility(
            model: profile.requestedModelID,
            expectedReturnedModelID: profile.expectedReturnedModelID,
            reasoningEffort: effort,
            callSite: .agentTurn,
            backendIncludesCloud: true,
            cloudEvaluatedResultCount: 0
        )

        #expect(reason == .cloudEvaluationRequired)
        #expect(reason?.description.contains("no backend-available cloud results") == true)
    }

    @Test func committedDocsRequireTheProductionReasoningEffort() {
        let profile = CloudModelCatalog.productionProfile
        let recordedEfforts: [String?] = [nil] + ReasoningEffort.allCases.map(\.rawValue)
        for callSite in [CloudCallSite.agentTurn, .oneShotSQL] {
            let production = profile.policy(for: callSite).reasoningEffort?.rawValue
            func ineligibility(_ effort: String?) -> TextToSQLReleaseGateModelPolicy.CommittedDocIneligibility? {
                TextToSQLReleaseGateModelPolicy.committedDocIneligibility(
                    model: profile.requestedModelID,
                    expectedReturnedModelID: profile.expectedReturnedModelID,
                    reasoningEffort: effort,
                    callSite: callSite,
                    backendIncludesCloud: true,
                    cloudEvaluatedResultCount: 1
                )
            }

            #expect(ineligibility(production) == nil, "\(callSite)")
            // Any other effort, or none when production sends one, is an
            // eval-only override: even with --allow-model-override it never
            // publishes the committed docs.
            for effort in recordedEfforts where effort != production {
                #expect(
                    ineligibility(effort)
                        == .productionReasoningEffortRequired(actual: effort, expected: production),
                    "\(callSite) \(effort ?? "nil")"
                )
            }
        }

        let reason = TextToSQLReleaseGateModelPolicy.CommittedDocIneligibility
            .productionReasoningEffortRequired(actual: "low", expected: "high")
        #expect(reason.description.contains("reasoning effort is low"))
        #expect(reason.description.contains("production high"))
        #expect(reason.description.contains(profile.requestedModelID))
    }

    @Test func releaseGateViolationHasAnActionableLocalizedDescription() {
        let pinned = CloudModelCatalog.productionProfile.requestedModelID
        let violation = TextToSQLReleaseGateModelPolicy.Violation(model: nil)

        #expect(violation.pinnedModel == pinned)
        #expect(violation.localizedDescription.contains("require a cloud run"))
        #expect(violation.localizedDescription.contains("--allow-model-override"))
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

    @Test func releaseGateModelPolicyRejectsReasoningEffortOverridesWithoutTheOverrideFlag() {
        let pinned = CloudModelCatalog.productionProfile.requestedModelID
        let violation = TextToSQLReleaseGateModelPolicy.Violation(
            model: pinned,
            reasoningEffortOverride: .low
        )
        for (gateVersion, triageVersion) in [("0.2.0", nil), (nil, "0.2.0")] as [(String?, String?)] {
            #expect(throws: violation) {
                try TextToSQLReleaseGateModelPolicy.validate(
                    model: pinned,
                    reasoningEffortOverride: .low,
                    backendIncludesCloud: true,
                    releaseGateVersion: gateVersion,
                    releaseTriageVersion: triageVersion,
                    allowModelOverride: false
                )
            }
            #expect(throws: Never.self) {
                try TextToSQLReleaseGateModelPolicy.validate(
                    model: pinned,
                    reasoningEffortOverride: .low,
                    backendIncludesCloud: true,
                    releaseGateVersion: gateVersion,
                    releaseTriageVersion: triageVersion,
                    allowModelOverride: true
                )
            }
        }
        #expect(throws: Never.self) {
            try TextToSQLReleaseGateModelPolicy.validate(
                model: pinned,
                reasoningEffortOverride: .low,
                backendIncludesCloud: true,
                releaseGateVersion: nil,
                releaseTriageVersion: nil,
                allowModelOverride: false
            )
        }
        // An unpinned model is reported as the model violation it already was.
        #expect(throws: TextToSQLReleaseGateModelPolicy.Violation(model: "vendor/other")) {
            try TextToSQLReleaseGateModelPolicy.validate(
                model: "vendor/other",
                reasoningEffortOverride: .low,
                backendIncludesCloud: true,
                releaseGateVersion: "0.2.0",
                releaseTriageVersion: nil,
                allowModelOverride: false
            )
        }
        #expect(violation.localizedDescription.contains("--reasoning-effort low"))
        #expect(violation.localizedDescription.contains(pinned))
        #expect(violation.localizedDescription.contains("--allow-model-override"))
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
}
