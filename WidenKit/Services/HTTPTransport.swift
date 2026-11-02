import Foundation

/// Sends one HTTP request and returns the body and response. The seam that
/// lets cloud generators be unit-tested without a network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Production transport backed by an ephemeral URLSession. It never follows
/// a redirect: `CloudModelProfile.authorizedRequest` checks only the URL it
/// signs, so a 3xx comes back to the caller as an HTTP error instead of
/// carrying the Authorization header to a URL nothing checked.
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
        self.init(configuration: configuration)
    }

    init(configuration: URLSessionConfiguration) {
        self.session = URLSession(configuration: configuration)
    }

    var sessionConfiguration: URLSessionConfiguration {
        session.configuration
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(
            for: request,
            delegate: RedirectRefusingTaskDelegate.shared
        )
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// Refuses every HTTP redirect, so the task finishes with the 3xx response
/// itself. A task delegate rather than a session delegate, so sessions are
/// not kept alive by a delegate reference.
private final class RedirectRefusingTaskDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RedirectRefusingTaskDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
