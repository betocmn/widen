import Foundation
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
