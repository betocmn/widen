import Foundation
import Testing

@testable import WidenKit

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
