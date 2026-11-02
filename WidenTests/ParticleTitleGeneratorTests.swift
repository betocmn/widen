import Foundation
import Testing

@testable import WidenKit

@Suite("Particle title generator")
struct ParticleTitleGeneratorTests {
    private static let apiKey = "pai-test-0123456789abcdef"

    /// A reply the generator must refuse, so the session keeps its
    /// deterministic title.
    struct RejectedReply: Sendable, CustomTestStringConvertible {
        var label: String
        var status = 200
        var model: String? = ParticleTestSupport.returnedModelID
        var content: String? = "Top Spenders"
        var finishReason = "stop"

        var testDescription: String { label }
    }

    /// Never answers on its own; it waits until the request is cancelled and
    /// records that it was.
    private final class StalledTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var sawCancellation: Bool {
            lock.withLock { cancelled }
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                lock.withLock { cancelled = true }
                throw error
            }
            return (Data(), RecordingTransport.response(to: request))
        }
    }

    @Test func sendsOnlyTheQuestionToParticleWithReasoningOff() async throws {
        let transport = Self.replying(content: "Top Spenders")
        let generator = ParticleTitleGenerator(apiKey: Self.apiKey, transport: transport)

        let title = try await generator.generateTitle(for: "  Which users have spent the most?\n")

        #expect(title == "Top Spenders")
        let requests = transport.requests
        try #require(requests.count == 1)
        let request = requests[0]
        #expect(request.url?.host == "api.particle.ai")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.apiKey)")
        let body = try ParticleTestSupport.expectRequestShape(
            request,
            callSite: .sessionTitle,
            profile: .particle,
            requiresPromptCacheKey: false
        )
        #expect(body["reasoning_effort"] as? String == "none")
        let maxCompletionTokens = try #require(body["max_completion_tokens"] as? Int)
        #expect(maxCompletionTokens <= 64)
        #expect(body["tools"] == nil)
        #expect(body["response_format"] == nil)
        #expect(body["temperature"] == nil)
        #expect(Set(body.keys) == ["model", "messages", "stream", "max_completion_tokens", "reasoning_effort"])

        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [
            ["role": "system", "content": ParticleTitleGenerator.instructions],
            ["role": "user", "content": "Question: Which users have spent the most?"],
        ])
        let sentBody = try #require(request.httpBody)
        let sentText = String(decoding: sentBody, as: UTF8.self)
        for schemaWord in ["schema", "table", "column", "CREATE", "public."] {
            #expect(!sentText.contains(schemaWord), "title request mentions \(schemaWord)")
        }
    }

    @Test func stripsALeadingTitleLabel() async throws {
        let transport = Self.replying(content: "  Title: Orders By Status ")
        let generator = ParticleTitleGenerator(apiKey: Self.apiKey, transport: transport)

        #expect(try await generator.generateTitle(for: "orders by status") == "Orders By Status")
    }

    @Test func truncatesTheQuestionTo500Characters() async throws {
        let transport = Self.replying(content: "Long Question")
        let generator = ParticleTitleGenerator(apiKey: Self.apiKey, transport: transport)
        let question = String(repeating: "a", count: 450) + String(repeating: "b", count: 150)

        _ = try await generator.generateTitle(for: question)

        let body = try Self.jsonBody(try #require(transport.requests.first))
        let messages = try #require(body["messages"] as? [[String: String]])
        let userContent = try #require(messages.last?["content"])
        #expect(userContent == "Question: " + String(question.prefix(500)))
        #expect(userContent.count == "Question: ".count + ParticleTitleGenerator.maxQuestionCharacters)
        #expect(userContent.hasSuffix(String(repeating: "b", count: 50)))
    }

    @Test(arguments: [
        RejectedReply(label: "another returned model", model: "openai/gpt-5.5"),
        RejectedReply(label: "no returned model", model: nil),
        RejectedReply(label: "empty content", content: ""),
        RejectedReply(label: "missing content", content: nil),
        RejectedReply(label: "only a title label", content: "Title:"),
        RejectedReply(label: "hit the token cap", finishReason: "length"),
        RejectedReply(label: "unexpected finish reason", finishReason: "tool_calls"),
        RejectedReply(label: "non-200 success status", status: 203),
        RejectedReply(label: "rejected key", status: 401),
        RejectedReply(label: "retryable outage", status: 503),
    ])
    func refusesAnythingButAStoppedTitleFromParticle1(reply: RejectedReply) async throws {
        let transport = RecordingTransport { request, _ in
            (Self.completion(reply), RecordingTransport.response(to: request, status: reply.status))
        }
        let generator = ParticleTitleGenerator(apiKey: Self.apiKey, transport: transport)

        await #expect(throws: CloudRequestFailure.self) {
            try await generator.generateTitle(for: "Which users have spent the most?")
        }
        // Titles are best-effort, so nothing is ever retried.
        #expect(transport.requests.count == 1)
    }

    @Test func timeoutCancelsTheRequestInFlight() async throws {
        let transport = StalledTransport()
        let generator = ParticleTitleGenerator(
            apiKey: Self.apiKey,
            transport: transport,
            timeoutSeconds: 0.05
        )
        let started = Date()

        let error = await #expect(throws: CloudRequestFailure.self) {
            try await generator.generateTitle(for: "Which users have spent the most?")
        }

        #expect(error?.category == .timeout)
        #expect(transport.sawCancellation)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func refusesAForeignKeyBeforeSendingAnything() async {
        let transport = Self.replying(content: "Top Spenders")
        let generator = ParticleTitleGenerator(apiKey: "sk-or-v1-0123", transport: transport)

        await #expect(throws: CloudRequestFailure.self) {
            try await generator.generateTitle(for: "Which users have spent the most?")
        }
        #expect(transport.requests.isEmpty)
    }

    // MARK: - Fixtures

    private static func replying(content: String) -> RecordingTransport {
        RecordingTransport { request, _ in
            (
                completion(RejectedReply(label: "title", content: content)),
                RecordingTransport.response(to: request)
            )
        }
    }

    private static func completion(_ reply: RejectedReply) -> Data {
        guard (200..<300).contains(reply.status) else {
            return jsonData([
                "error": [
                    "message": "Request failed.",
                    "type": reply.status == 401 ? "authentication_error" : "server_error",
                    "code": reply.status == 401 ? "invalid_bearer_credential" : "model_unavailable",
                ]
            ])
        }
        var message: [String: Any] = ["role": "assistant"]
        message["content"] = reply.content
        var response: [String: Any] = [
            "id": "chatcmpl-title",
            "object": "chat.completion",
            "choices": [
                ["index": 0, "finish_reason": reply.finishReason, "message": message]
            ],
            "usage": ["prompt_tokens": 40, "completion_tokens": 4, "total_tokens": 44],
        ]
        response["model"] = reply.model
        return jsonData(response)
    }

    private static func jsonData(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private static func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
