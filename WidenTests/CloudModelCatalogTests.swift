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
        #expect(profile.parallelToolCalls == nil)
        #expect(!profile.usesPromptCacheKey)
        #expect(!profile.echoesReasoningContent)
        #expect(profile.sendsToolMessageName)
        #expect(profile.usesOpenRouterRouting)
        #expect(profile.requestTimeoutSeconds == 90)
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
        #expect(
            TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: profile.requestedModelID,
                expectedReturnedModelID: profile.expectedReturnedModelID,
                backendIncludesCloud: true,
                cloudEvaluatedResultCount: 1
            )
        )
        #expect(
            !TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: nil,
                expectedReturnedModelID: profile.expectedReturnedModelID,
                backendIncludesCloud: true,
                cloudEvaluatedResultCount: 1
            )
        )
        #expect(
            !TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: profile.requestedModelID,
                expectedReturnedModelID: profile.expectedReturnedModelID,
                backendIncludesCloud: false,
                cloudEvaluatedResultCount: 1
            )
        )
        #expect(
            !TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: "vendor/other",
                expectedReturnedModelID: profile.expectedReturnedModelID,
                backendIncludesCloud: true,
                cloudEvaluatedResultCount: 1
            )
        )
        #expect(
            !TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: profile.requestedModelID,
                expectedReturnedModelID: nil,
                backendIncludesCloud: true,
                cloudEvaluatedResultCount: 1
            )
        )
        #expect(
            !TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: profile.requestedModelID,
                expectedReturnedModelID: "openai/gpt-5.5-unevaluated",
                backendIncludesCloud: true,
                cloudEvaluatedResultCount: 1
            )
        )
        #expect(
            !TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: profile.requestedModelID,
                expectedReturnedModelID: profile.expectedReturnedModelID,
                backendIncludesCloud: true,
                cloudEvaluatedResultCount: 0
            )
        )
    }

    @Test func committedDocIneligibilityExplainsMissingExecutionEvidence() {
        let profile = CloudModelCatalog.productionProfile
        let reason = TextToSQLReleaseGateModelPolicy.committedDocIneligibility(
            model: profile.requestedModelID,
            expectedReturnedModelID: profile.expectedReturnedModelID,
            backendIncludesCloud: true,
            cloudEvaluatedResultCount: 0
        )

        #expect(reason == .cloudEvaluationRequired)
        #expect(reason?.description.contains("no backend-available cloud results") == true)
    }

    @Test func releaseGateViolationHasAnActionableLocalizedDescription() {
        let pinned = CloudModelCatalog.productionProfile.requestedModelID
        let violation = TextToSQLReleaseGateModelPolicy.Violation(model: nil)

        #expect(violation.pinnedModel == pinned)
        #expect(violation.localizedDescription.contains("require a cloud run"))
        #expect(violation.localizedDescription.contains("--allow-model-override"))
    }

    @Test func expectedReturnedModelIDEnforcesOnlyThePinnedModel() throws {
        let profile = CloudModelCatalog.productionProfile
        let expectedReturnedModelID = try #require(profile.expectedReturnedModelID)
        #expect(
            CloudModelCatalog.expectedReturnedModelID(
                forRequestedModelID: profile.requestedModelID
            ) == profile.expectedReturnedModelID
        )
        #expect(
            CloudModelCatalog.expectedReturnedModelID(forRequestedModelID: "vendor/other-model")
                == nil
        )
        #expect(
            CloudModelCatalog.expectedReturnedModelID(
                forRequestedModelID: expectedReturnedModelID
            ) == nil
        )
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
