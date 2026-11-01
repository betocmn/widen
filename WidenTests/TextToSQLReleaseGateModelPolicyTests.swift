import Foundation
import Testing

@testable import WidenKit

@Suite("Release-gate model policy")
struct TextToSQLReleaseGateModelPolicyTests {
    private typealias Policy = TextToSQLReleaseGateModelPolicy

    private static let pinnedModel = "particle-1"
    private static let pinnedReturnedModel = "particle-ai/particle-1"
    /// The effort a default tools-agent Particle-1 run records in its manifest.
    private static let productionEffort = CloudModelProfile.particle
        .policy(for: .agentTurn).reasoningEffort?.rawValue
    private static let docVersions: [(gate: String?, triage: String?)] = [
        ("0.2.0", nil), (nil, "0.2.0"), ("0.2.0", "0.2.0"),
    ]

    @Test func releaseGatePublicationIsPinnedToParticle1() {
        let profile = Policy.pinnedProfile
        #expect(profile == CloudModelCatalog.productionProfile)
        #expect(profile == .particle)
        #expect(profile.requestedModelID == Self.pinnedModel)
        #expect(profile.expectedReturnedModelID == Self.pinnedReturnedModel)
        #expect(Policy.Violation(model: nil).pinnedModel == Self.pinnedModel)
        #expect(TextToSQLReleaseGate.expectedResultCount == 60)
    }

    @Test func pinnedParticle1RunPassesAndPublishes() {
        for versions in Self.docVersions {
            #expect(throws: Never.self) {
                try Policy.validate(
                    model: Self.pinnedModel,
                    releaseGateVersion: versions.gate,
                    releaseTriageVersion: versions.triage,
                    allowModelOverride: false
                )
            }
        }
        #expect(
            Policy.canPublishCommittedDocs(
                model: Self.pinnedModel,
                expectedReturnedModelID: Self.pinnedReturnedModel,
                reasoningEffort: Self.productionEffort,
                callSite: .agentTurn,
                cloudEvaluatedResultCount: 1
            )
        )
    }

    @Test func otherModelsFailWithoutTheOverride() {
        let models: [String?] = [
            "vendor/other", "openai/gpt-5.5", "openai/gpt-5.5-20260423",
            Self.pinnedReturnedModel, "Particle-1", nil,
        ]
        for model in models {
            for versions in Self.docVersions {
                #expect(throws: Policy.Violation(model: model), "\(model ?? "nil")") {
                    try Policy.validate(
                        model: model,
                        releaseGateVersion: versions.gate,
                        releaseTriageVersion: versions.triage,
                        allowModelOverride: false
                    )
                }
            }
        }
    }

    @Test func overriddenComparisonRunsPassButNeverPublish() {
        for model in ["openai/gpt-5.5", "vendor/other"] {
            for versions in Self.docVersions {
                #expect(throws: Never.self) {
                    try Policy.validate(
                        model: model,
                        releaseGateVersion: versions.gate,
                        releaseTriageVersion: versions.triage,
                        allowModelOverride: true
                    )
                }
            }
        }

        // A GPT-5.5 comparison manifest records OpenRouter's dated returned
        // model and no reasoning effort; it still publishes nothing.
        let gpt55 = CloudModelProfile.openRouterGPT55
        let reason = Policy.committedDocIneligibility(
            model: gpt55.requestedModelID,
            expectedReturnedModelID: gpt55.expectedReturnedModelID,
            reasoningEffort: gpt55.policy(for: .agentTurn).reasoningEffort?.rawValue,
            callSite: .agentTurn,
            cloudEvaluatedResultCount: 60
        )
        #expect(reason == .pinnedModelRequired(actual: "openai/gpt-5.5"))
    }

    @Test func runsThatPublishNoDocsPassWithAnyModel() {
        for model in ["vendor/other", "openai/gpt-5.5", Self.pinnedModel] {
            #expect(throws: Never.self) {
                try Policy.validate(
                    model: model,
                    reasoningEffortOverride: .low,
                    releaseGateVersion: nil,
                    releaseTriageVersion: nil,
                    allowModelOverride: false
                )
            }
        }
        #expect(throws: Never.self) {
            try Policy.validate(
                model: nil,
                releaseGateVersion: nil,
                releaseTriageVersion: nil,
                allowModelOverride: false
            )
        }
    }

    @Test func releaseArtifactVersionsCannotEscapeTheirOutputDirectory() {
        for version in ["0.1.0", "0.2.0", "1.0-beta_1"] {
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
            try Policy.validate(
                model: "vendor/other",
                releaseGateVersion: "../README",
                releaseTriageVersion: nil,
                allowModelOverride: true
            )
        }
        #expect(throws: TextToSQLReleaseArtifactVersionPolicy.Violation.self) {
            try Policy.validate(
                model: Self.pinnedModel,
                releaseGateVersion: nil,
                releaseTriageVersion: "0.2/../../README",
                allowModelOverride: false
            )
        }
    }

    @Test func committedDocsRequireTheRequestedPinnedModel() {
        for model in ["openai/gpt-5.5", "vendor/other", Self.pinnedReturnedModel, nil] as [String?] {
            #expect(
                Self.ineligibility(model: model) == .pinnedModelRequired(actual: model),
                "\(model ?? "nil")"
            )
        }

        let other = Policy.CommittedDocIneligibility.pinnedModelRequired(actual: "openai/gpt-5.5")
        #expect(other.description.contains("requested model is openai/gpt-5.5"))
        #expect(other.description.contains("MODEL=particle-1 (Particle-1)"))
        let missing = Policy.CommittedDocIneligibility.pinnedModelRequired(actual: nil)
        #expect(missing.description.contains("requested model is missing"))
    }

    @Test func committedDocsRequireTheVerifiedParticle1ReturnedModel() {
        for returned in [nil, "openai/gpt-5.5-20260423", "particle-ai/particle-1-unevaluated"] as [String?] {
            #expect(
                Self.ineligibility(expectedReturnedModelID: returned)
                    == .expectedReturnedModelRequired(actual: returned),
                "\(returned ?? "nil")"
            )
        }

        let reason = Policy.CommittedDocIneligibility
            .expectedReturnedModelRequired(actual: "openai/gpt-5.5-20260423")
        #expect(reason.description.contains("expected returned model is openai/gpt-5.5-20260423"))
        #expect(reason.description.contains("not particle-ai/particle-1"))
        #expect(reason.description.contains("MODEL=particle-1"))
        #expect(
            Policy.CommittedDocIneligibility.expectedReturnedModelRequired(actual: nil)
                .description.contains("expected returned model is missing")
        )
    }

    @Test func committedDocsRequireTheProductionReasoningEffort() {
        let profile = CloudModelProfile.particle
        let recordedEfforts: [String?] = [nil] + ReasoningEffort.allCases.map(\.rawValue)
        for callSite in [CloudCallSite.agentTurn, .oneShotSQL] {
            let production = profile.policy(for: callSite).reasoningEffort?.rawValue
            #expect(production != nil, "\(callSite)")
            #expect(
                Self.ineligibility(reasoningEffort: production, callSite: callSite) == nil,
                "\(callSite)"
            )
            // Any other effort, or none when production sends one, is an
            // eval-only override: even with --allow-model-override it never
            // publishes the committed docs.
            for effort in recordedEfforts where effort != production {
                #expect(
                    Self.ineligibility(reasoningEffort: effort, callSite: callSite)
                        == .productionReasoningEffortRequired(actual: effort, expected: production),
                    "\(callSite) \(effort ?? "nil")"
                )
            }
        }

        let reason = Policy.CommittedDocIneligibility
            .productionReasoningEffortRequired(actual: "low", expected: "high")
        #expect(reason.description.contains("reasoning effort is low"))
        #expect(reason.description.contains("production high"))
        #expect(reason.description.contains("MODEL=particle-1"))
        #expect(
            Policy.CommittedDocIneligibility
                .productionReasoningEffortRequired(actual: nil, expected: "high")
                .description.contains("reasoning effort is unset")
        )
    }

    @Test func committedDocsRequireBackendAvailableCloudResults() {
        let reason = Self.ineligibility(cloudEvaluatedResultCount: 0)

        #expect(reason == .cloudEvaluationRequired)
        #expect(reason?.description.contains("no backend-available cloud results") == true)
        #expect(
            !Policy.canPublishCommittedDocs(
                model: Self.pinnedModel,
                expectedReturnedModelID: Self.pinnedReturnedModel,
                reasoningEffort: Self.productionEffort,
                callSite: .agentTurn,
                cloudEvaluatedResultCount: 0
            )
        )
    }

    @Test func releaseGateViolationsNameTheParticle1ModelArgument() {
        let missing = Policy.Violation(model: nil)
        #expect(missing.localizedDescription.contains("require MODEL=particle-1 (Particle-1)"))
        #expect(missing.localizedDescription.contains("recorded no model"))
        #expect(missing.localizedDescription.contains("--allow-model-override"))

        let other = Policy.Violation(model: "openai/gpt-5.5")
        #expect(other.localizedDescription.contains("require MODEL=particle-1 (Particle-1)"))
        #expect(other.localizedDescription.contains("got MODEL=openai/gpt-5.5"))
        #expect(other.localizedDescription.contains("--allow-model-override"))
    }

    @Test func releaseGateModelPolicyRejectsReasoningEffortOverridesWithoutTheOverrideFlag() {
        let violation = Policy.Violation(model: Self.pinnedModel, reasoningEffortOverride: .low)
        for versions in Self.docVersions {
            #expect(throws: violation) {
                try Policy.validate(
                    model: Self.pinnedModel,
                    reasoningEffortOverride: .low,
                    releaseGateVersion: versions.gate,
                    releaseTriageVersion: versions.triage,
                    allowModelOverride: false
                )
            }
            #expect(throws: Never.self) {
                try Policy.validate(
                    model: Self.pinnedModel,
                    reasoningEffortOverride: .low,
                    releaseGateVersion: versions.gate,
                    releaseTriageVersion: versions.triage,
                    allowModelOverride: true
                )
            }
        }
        // An unpinned model is reported as the model violation it already was.
        #expect(throws: Policy.Violation(model: "vendor/other")) {
            try Policy.validate(
                model: "vendor/other",
                reasoningEffortOverride: .low,
                releaseGateVersion: "0.2.0",
                releaseTriageVersion: nil,
                allowModelOverride: false
            )
        }
        #expect(violation.localizedDescription.contains("--reasoning-effort low"))
        #expect(violation.localizedDescription.contains("MODEL=particle-1 (Particle-1)"))
        #expect(violation.localizedDescription.contains("--allow-model-override"))
        // Even run with the override, the effort keeps the docs unpublished.
        #expect(
            Self.ineligibility(reasoningEffort: ReasoningEffort.low.rawValue)
                == .productionReasoningEffortRequired(actual: "low", expected: Self.productionEffort)
        )
    }

    /// The committed-doc check for a pinned, verified, evaluated tools-agent
    /// run, with one field replaced.
    private static func ineligibility(
        model: String? = pinnedModel,
        expectedReturnedModelID: String? = pinnedReturnedModel,
        reasoningEffort: String? = productionEffort,
        callSite: CloudCallSite = .agentTurn,
        cloudEvaluatedResultCount: Int = 60
    ) -> Policy.CommittedDocIneligibility? {
        Policy.committedDocIneligibility(
            model: model,
            expectedReturnedModelID: expectedReturnedModelID,
            reasoningEffort: reasoningEffort,
            callSite: callSite,
            cloudEvaluatedResultCount: cloudEvaluatedResultCount
        )
    }
}
