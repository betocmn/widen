import Testing

@testable import WidenKit

@Suite("OpenRouter production profile")
struct OpenRouterCatalogTests {
    @Test func productionProfilePinsDistinctRequestedAndCanonicalIDs() {
        let profile = OpenRouterCatalog.productionProfile
        #expect(!profile.requestedModelID.isEmpty)
        #expect(!profile.expectedCanonicalModelID.isEmpty)
        #expect(profile.requestedModelID != profile.expectedCanonicalModelID)
        #expect(!profile.displayName.isEmpty)
    }

    @Test func releaseGateModelPolicyRejectsUnpinnedDocPublishingRuns() {
        let pinned = OpenRouterCatalog.productionProfile.requestedModelID
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
        let profile = OpenRouterCatalog.productionProfile
        #expect(
            TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: profile.requestedModelID,
                expectedCanonicalModelID: profile.expectedCanonicalModelID,
                backendIncludesCloud: true,
                cloudEvaluatedResultCount: 1
            )
        )
        #expect(
            !TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: nil,
                expectedCanonicalModelID: profile.expectedCanonicalModelID,
                backendIncludesCloud: true,
                cloudEvaluatedResultCount: 1
            )
        )
        #expect(
            !TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: profile.requestedModelID,
                expectedCanonicalModelID: profile.expectedCanonicalModelID,
                backendIncludesCloud: false,
                cloudEvaluatedResultCount: 1
            )
        )
        #expect(
            !TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: "vendor/other",
                expectedCanonicalModelID: profile.expectedCanonicalModelID,
                backendIncludesCloud: true,
                cloudEvaluatedResultCount: 1
            )
        )
        #expect(
            !TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: profile.requestedModelID,
                expectedCanonicalModelID: nil,
                backendIncludesCloud: true,
                cloudEvaluatedResultCount: 1
            )
        )
        #expect(
            !TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: profile.requestedModelID,
                expectedCanonicalModelID: "openai/gpt-5.5-unevaluated",
                backendIncludesCloud: true,
                cloudEvaluatedResultCount: 1
            )
        )
        #expect(
            !TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: profile.requestedModelID,
                expectedCanonicalModelID: profile.expectedCanonicalModelID,
                backendIncludesCloud: true,
                cloudEvaluatedResultCount: 0
            )
        )
    }

    @Test func committedDocIneligibilityExplainsMissingExecutionEvidence() {
        let profile = OpenRouterCatalog.productionProfile
        let reason = TextToSQLReleaseGateModelPolicy.committedDocIneligibility(
            model: profile.requestedModelID,
            expectedCanonicalModelID: profile.expectedCanonicalModelID,
            backendIncludesCloud: true,
            cloudEvaluatedResultCount: 0
        )

        #expect(reason == .cloudEvaluationRequired)
        #expect(reason?.description.contains("no backend-available cloud results") == true)
    }

    @Test func releaseGateViolationHasAnActionableLocalizedDescription() {
        let pinned = OpenRouterCatalog.productionProfile.requestedModelID
        let violation = TextToSQLReleaseGateModelPolicy.Violation(model: nil)

        #expect(violation.pinnedModel == pinned)
        #expect(violation.localizedDescription.contains("require a cloud run"))
        #expect(violation.localizedDescription.contains("--allow-model-override"))
    }

    @Test func expectedCanonicalModelIDEnforcesOnlyThePinnedModel() {
        let profile = OpenRouterCatalog.productionProfile
        #expect(
            OpenRouterCatalog.expectedCanonicalModelID(
                forRequestedModelID: profile.requestedModelID
            ) == profile.expectedCanonicalModelID
        )
        #expect(
            OpenRouterCatalog.expectedCanonicalModelID(forRequestedModelID: "vendor/other-model")
                == nil
        )
        #expect(
            OpenRouterCatalog.expectedCanonicalModelID(
                forRequestedModelID: profile.expectedCanonicalModelID
            ) == nil
        )
    }
}
