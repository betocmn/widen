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
