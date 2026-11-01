import Foundation

/// Sends one HTTP request and returns the body and response. The seam that
/// lets cloud generators be unit-tested without a network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Production transport backed by an ephemeral URLSession.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    /// `timeout` is how long a request may wait for more data;
    /// `resourceTimeout` bounds the whole transfer, and `nil` keeps
    /// URLSession's default.
    public init(timeout: TimeInterval = 90, resourceTimeout: TimeInterval? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        if let resourceTimeout {
            configuration.timeoutIntervalForResource = resourceTimeout
        }
        self.session = URLSession(configuration: configuration)
    }

    var sessionConfiguration: URLSessionConfiguration {
        session.configuration
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}
