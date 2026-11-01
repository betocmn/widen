import Foundation
import Testing

@testable import WidenKit

extension CloudModelProfile {
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
