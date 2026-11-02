import Foundation

/// Names a session with one Particle-1 call. Only the first question is
/// sent, at most `maxQuestionCharacters` of it: no schema, no database
/// context and no results. The request uses the profile's session-title call
/// site (reasoning off, a 64-token cap, no tools, no `response_format`) and is
/// sent once, with no retries. Any failure throws, so the caller falls back to
/// the deterministic title.
public struct ParticleTitleGenerator: SessionTitleGenerating {
    public static let defaultTimeoutSeconds: TimeInterval = 10
    static let maxQuestionCharacters = 500
    static let instructions =
        "You name database query sessions. Reply with only a title of two to five words in Title Case. No quotes, punctuation, or SQL keywords."

    private let apiKey: String
    let profile: CloudModelProfile
    private let transport: any HTTPTransport
    let timeoutSeconds: TimeInterval

    /// Requests go only to `profile`'s host. Without a transport, one is
    /// built with the title timeout.
    public init(
        apiKey: String,
        profile: CloudModelProfile = .particle,
        transport: (any HTTPTransport)? = nil,
        timeoutSeconds: TimeInterval = Self.defaultTimeoutSeconds
    ) {
        self.apiKey = apiKey
        self.profile = profile
        self.transport = transport ?? URLSessionTransport(timeout: timeoutSeconds)
        self.timeoutSeconds = timeoutSeconds
    }

    public func generateTitle(for question: String) async throws -> String {
        let built = try ChatCompletionRequestBuilder(profile: profile).build(
            apiKey: apiKey,
            instructions: Self.instructions,
            prompt: Self.prompt(for: question),
            capabilities: capabilities,
            callSite: .sessionTitle
        )
        let request = built.request
        // Whichever finishes first wins; leaving the group cancels the other,
        // so a timeout also cancels the request in flight.
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await send(request) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw CloudRequestFailure(
                    category: .timeout,
                    message: "\(profile.displayName) did not name the session within \(Int(timeoutSeconds.rounded(.up))) seconds.",
                    requestedModelID: profile.requestedModelID
                )
            }
            defer { group.cancelAll() }
            guard let title = try await group.next() else { throw CancellationError() }
            return title
        }
    }

    /// The only user message: the trimmed question, cut to
    /// `maxQuestionCharacters`.
    static func prompt(for question: String) -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Question: " + String(trimmed.prefix(maxQuestionCharacters))
    }

    /// Sends the request once and returns the reply's text, minus any
    /// leading "Title:". The shared parser maps provider errors and checks
    /// the returned model before any content is read.
    private func send(_ request: URLRequest) async throws -> String {
        let (data, response) = try await transport.send(request)
        let turn = try ChatToolParser(profile: profile).parse(
            data: data,
            response: response,
            requestedModelID: profile.requestedModelID,
            requestCount: 1,
            retryCount: 0
        )
        guard response.statusCode == 200,
            turn.toolCalls.isEmpty,
            turn.metadata.finishReason == "stop",
            let title = turn.content.map(Self.strippingTitleLabel),
            !title.isEmpty
        else {
            throw CloudRequestFailure(
                category: .malformedStructuredResponse,
                message: "\(profile.displayName) did not reply with a session title.",
                httpStatus: response.statusCode,
                completionID: turn.metadata.completionID,
                requestID: turn.metadata.requestID,
                requestedModelID: profile.requestedModelID,
                returnedModelID: turn.metadata.returnedModelID,
                providerName: turn.metadata.providerName
            )
        }
        return title
    }

    private static func strippingTitleLabel(_ content: String) -> String {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.range(of: "title:", options: [.caseInsensitive, .anchored]) != nil {
            text = String(text.dropFirst("title:".count))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var capabilities: CloudModelCapabilities {
        if case .staticCapabilities(let capabilities) = profile.capabilityResolution {
            return capabilities
        }
        return .conservative()
    }
}
