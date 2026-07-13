import Foundation
import Testing

@testable import WidenKit

enum OpenRouterTestSupport {
    /// Asserts a request body carries exactly the production private-routing
    /// provider preferences, derived from the production constant so every
    /// suite tracks future changes to `requiredPrivateRouting`.
    static func expectPrivateRouting(inBody body: [String: Any]) throws {
        let provider = try #require(body["provider"] as? [String: Any])
        let expected = OpenRouterProviderPreferences.requiredPrivateRouting
        #expect(provider["require_parameters"] as? Bool == expected.requireParameters)
        #expect(provider["zdr"] as? Bool == expected.zdr)
        #expect(provider["data_collection"] as? String == expected.dataCollection)
        #expect(provider.count == 3)
    }
}
